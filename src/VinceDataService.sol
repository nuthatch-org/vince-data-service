// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

// ============================================================================
//
//   VinceDataService — Find All Vince Worldwide
//
//   A decentralised, permissionless, cryptographically-secured data service
//   for the location and cataloguing of individuals named Vince.
//
//   Inspired by the legendary Josh Fight (https://en.wikipedia.org/wiki/Josh_fight)
//   and the visionary question posed in The Graph Discord:
//   "When @Vince | Nodeify data service? (Find all Vince worldwide)"
//
//   This is a real Horizon data service. It compiles. It deploys.
//   It moves GRT. The Vinces are not real. The payments are.
//
// ============================================================================

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {DataService} from "@graphprotocol/horizon/data-service/DataService.sol";
import {DataServiceFees} from "@graphprotocol/horizon/data-service/extensions/DataServiceFees.sol";
import {DataServicePausable} from "@graphprotocol/horizon/data-service/extensions/DataServicePausable.sol";
import {IGraphTallyCollector} from "@graphprotocol/horizon/interfaces/IGraphTallyCollector.sol";
import {IGraphPayments} from "@graphprotocol/horizon/interfaces/IGraphPayments.sol";

contract VinceDataService is Ownable, DataService, DataServiceFees, DataServicePausable {

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    /// @notice Coverage tier for Vince discovery operations.
    enum VinceTier {
        SIGHTING,   // 0 — unconfirmed Vince sighting; provider says "there's a Vince around here somewhere"
        CONFIRMED,  // 1 — verified Vince presence; provider has made eye contact
        WORLDWIDE   // 2 — global Vince network; provider has eyes on all Vinces at all times
    }

    struct VinceRegion {
        string  geohash;    // geographic region this provider covers
        VinceTier tier;
        bool    active;
    }

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 public constant MIN_PROVISION      = 10_000e18; // 10,000 GRT — Vince-finding is serious business
    uint64  public constant MIN_THAWING_PERIOD = 14 days;   // Vinces do not thaw
    uint256 public constant STAKE_TO_FEES_RATIO = 5;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    IGraphTallyCollector public immutable GRAPH_TALLY_COLLECTOR;

    mapping(address => bool)          public registeredProviders;
    mapping(address => address)       public paymentsDestination;
    mapping(address => VinceRegion[]) internal _regions;

    /// @notice Total Vinces located across the entire network. On-chain. Forever.
    uint256 public totalVincesLocated;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event ProviderRegistered(address indexed provider, string operatorHandle);
    event ProviderDeregistered(address indexed provider);
    event VinceSightingActivated(address indexed provider, string geohash, VinceTier tier);
    event VinceSightingDeactivated(address indexed provider, string geohash, VinceTier tier);
    event VinceLocated(address indexed provider, uint256 vinceCount, uint256 totalVincesLocated);
    event PaymentsDestinationSet(address indexed provider, address indexed destination);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error ProviderAlreadyRegistered(address provider);
    error ProviderNotRegistered(address provider);
    error ActiveSightingsExist(address provider);
    error InvalidPaymentType();
    error InvalidServiceProvider(address expected, address got);
    error VinceNotFound();       // returned when geohash has no active providers
    error TooManyVinces();       // theoretical; included for completeness

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(
        address owner_,
        address controller,
        address graphTallyCollector,
        address pauseGuardian
    ) Ownable(owner_) DataService(controller) {
        GRAPH_TALLY_COLLECTOR = IGraphTallyCollector(graphTallyCollector);
        _setProvisionTokensRange(MIN_PROVISION, type(uint256).max);
        _setThawingPeriodRange(MIN_THAWING_PERIOD, type(uint64).max);
        _setVerifierCutRange(0, uint32(1_000_000));
        _setPauseGuardian(pauseGuardian, true);
    }

    // -------------------------------------------------------------------------
    // IDataService — provider lifecycle
    // -------------------------------------------------------------------------

    /// @notice Register as a Vince-finding provider.
    /// @param data abi.encode(string operatorHandle, address paymentsDestination)
    ///             operatorHandle — your Discord username, ideally "Vince | Something"
    function register(address serviceProvider, bytes calldata data)
        external override whenNotPaused onlyAuthorizedForProvision(serviceProvider)
    {
        if (registeredProviders[serviceProvider]) revert ProviderAlreadyRegistered(serviceProvider);

        _checkProvisionTokens(serviceProvider);
        _checkProvisionParameters(serviceProvider, false);

        (string memory operatorHandle, address dest) = abi.decode(data, (string, address));

        registeredProviders[serviceProvider] = true;
        paymentsDestination[serviceProvider] = dest == address(0) ? serviceProvider : dest;

        emit ProviderRegistered(serviceProvider, operatorHandle);
    }

    /// @notice Activate Vince-finding for a geographic region and tier.
    /// @param data abi.encode(string geohash, VinceTier tier)
    function startService(address serviceProvider, bytes calldata data)
        external override whenNotPaused onlyAuthorizedForProvision(serviceProvider)
    {
        if (!registeredProviders[serviceProvider]) revert ProviderNotRegistered(serviceProvider);

        (string memory geohash, VinceTier tier) = abi.decode(data, (string, VinceTier));

        // Reuse stopped slots to prevent unbounded array growth across many start/stop cycles.
        VinceRegion[] storage regions = _regions[serviceProvider];
        for (uint256 i = 0; i < regions.length; i++) {
            if (!regions[i].active) {
                regions[i] = VinceRegion({geohash: geohash, tier: tier, active: true});
                emit VinceSightingActivated(serviceProvider, geohash, tier);
                return;
            }
        }
        regions.push(VinceRegion({geohash: geohash, tier: tier, active: true}));
        emit VinceSightingActivated(serviceProvider, geohash, tier);
    }

    /// @notice Deactivate Vince-finding for a specific region and tier.
    /// @param data abi.encode(uint256 regionIndex)
    function stopService(address serviceProvider, bytes calldata data)
        external override whenNotPaused onlyAuthorizedForProvision(serviceProvider)
    {
        if (!registeredProviders[serviceProvider]) revert ProviderNotRegistered(serviceProvider);

        uint256 idx = abi.decode(data, (uint256));
        VinceRegion storage region = _regions[serviceProvider][idx];
        emit VinceSightingDeactivated(serviceProvider, region.geohash, region.tier);
        region.active = false;
    }

    /// @notice Deregister. All active sightings must be stopped first.
    ///         Note: deregister is NOT in IDataService — no override keyword.
    function deregister(address serviceProvider, bytes calldata)
        external onlyAuthorizedForProvision(serviceProvider)
    {
        if (!registeredProviders[serviceProvider]) revert ProviderNotRegistered(serviceProvider);
        if (activeRegionCount(serviceProvider) > 0) revert ActiveSightingsExist(serviceProvider);

        registeredProviders[serviceProvider] = false;
        emit ProviderDeregistered(serviceProvider);
    }

    /// @notice Two-step provision parameter update.
    function acceptProvisionPendingParameters(address serviceProvider, bytes calldata)
        external override onlyAuthorizedForProvision(serviceProvider)
    {
        _acceptProvisionParameters(serviceProvider);
    }

    // -------------------------------------------------------------------------
    // collect() — GRT flows when Vinces are found
    // -------------------------------------------------------------------------

    /// @notice Redeem a signed RAV. Called after a batch of Vince-finding requests.
    ///         The `data` parameter encodes (SignedRAV, tokensToCollect).
    ///         Each query in the batch represents one or more Vinces located;
    ///         the fee per query is set by the gateway and provider off-chain.
    function collect(
        address serviceProvider,
        IGraphPayments.PaymentTypes paymentType,
        bytes calldata data
    ) external override whenNotPaused returns (uint256 fees) {
        if (paymentType != IGraphPayments.PaymentTypes.QueryFee) revert InvalidPaymentType();
        if (!registeredProviders[serviceProvider]) revert ProviderNotRegistered(serviceProvider);

        (IGraphTallyCollector.SignedRAV memory signedRav, uint256 tokensToCollect) =
            abi.decode(data, (IGraphTallyCollector.SignedRAV, uint256));

        if (signedRav.rav.serviceProvider != serviceProvider)
            revert InvalidServiceProvider(serviceProvider, signedRav.rav.serviceProvider);

        _releaseStake(serviceProvider, 0);

        fees = GRAPH_TALLY_COLLECTOR.collect(
            paymentType,
            abi.encode(
                signedRav,
                uint256(0),                          // dataServiceCut — Vince asks for nothing
                paymentsDestination[serviceProvider]
            ),
            tokensToCollect
        );

        if (fees > 0) {
            // A conservative estimate: assume each GRT wei of fees represents one Vince located.
            // This is not accurate. It is on-chain. It is permanent.
            totalVincesLocated += fees;
            emit VinceLocated(serviceProvider, fees, totalVincesLocated);

            _lockStake(serviceProvider, fees * STAKE_TO_FEES_RATIO, block.timestamp + MIN_THAWING_PERIOD);
        }
    }

    // -------------------------------------------------------------------------
    // slash() — Vince does not slash back
    // -------------------------------------------------------------------------

    function slash(address, bytes calldata) external pure override {
        // Vince is a lover, not a fighter.
        // See also: https://en.wikipedia.org/wiki/Josh_fight
        revert("Vince does not slash");
    }

    // -------------------------------------------------------------------------
    // View helpers
    // -------------------------------------------------------------------------

    function activeRegionCount(address provider) public view returns (uint256 count) {
        VinceRegion[] storage regions = _regions[provider];
        for (uint256 i = 0; i < regions.length; i++) {
            if (regions[i].active) count++;
        }
    }

    function getRegions(address provider) external view returns (VinceRegion[] memory) {
        return _regions[provider];
    }

    // -------------------------------------------------------------------------
    // paymentsDestination setter
    // -------------------------------------------------------------------------

    function setPaymentsDestination(address destination) external {
        if (!registeredProviders[msg.sender]) revert ProviderNotRegistered(msg.sender);
        paymentsDestination[msg.sender] = destination == address(0) ? msg.sender : destination;
        emit PaymentsDestinationSet(msg.sender, paymentsDestination[msg.sender]);
    }
}
