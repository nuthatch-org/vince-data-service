// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {VinceDataService} from "../src/VinceDataService.sol";
import {GraphPayments} from "@graphprotocol/horizon/payments/GraphPayments.sol";
import {PaymentsEscrow} from "@graphprotocol/horizon/payments/PaymentsEscrow.sol";
import {GraphTallyCollector} from "@graphprotocol/horizon/payments/collectors/GraphTallyCollector.sol";
import {MockGRTToken} from "@graphprotocol/horizon/mocks/MockGRTToken.sol";
import {ControllerMock} from "@graphprotocol/horizon/mocks/ControllerMock.sol";
import {IHorizonStakingTypes} from "@graphprotocol/interfaces/contracts/horizon/internal/IHorizonStakingTypes.sol";

contract MockStaking {
    mapping(address => mapping(address => IHorizonStakingTypes.Provision)) public provisions;

    function setProvision(address sp, address ds, uint256 tokens, uint64 thawingPeriod) external {
        provisions[sp][ds] = IHorizonStakingTypes.Provision({
            tokens: tokens, tokensThawing: 0, sharesThawing: 0,
            maxVerifierCut: 1_000_000, thawingPeriod: thawingPeriod,
            createdAt: uint64(block.timestamp), maxVerifierCutPending: 0,
            thawingPeriodPending: 0, lastParametersStagedAt: 0, thawingNonce: 0
        });
    }
    function getProvision(address sp, address ds) external view returns (IHorizonStakingTypes.Provision memory) {
        return provisions[sp][ds];
    }
    function isAuthorized(address sp, address, address op) external pure returns (bool) { return sp == op; }
    function getTokensAvailable(address sp, address ds, uint32) external view returns (uint256) {
        return provisions[sp][ds].tokens;
    }
    function getDelegationPool(address, address) external pure returns (IHorizonStakingTypes.DelegationPool memory) {
        return IHorizonStakingTypes.DelegationPool({tokens:0, shares:0, tokensThawing:0, sharesThawing:0, thawingNonce:0});
    }
    function slash(address, uint256, uint256, address) external {}
    function acceptProvisionParameters(address) external {}
}

contract Deploy is Script {
    uint256 constant DEPLOYER_KEY     = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 constant PROVIDER_KEY     = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 constant GATEWAY_KEY      = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 constant GATEWAY_SIGN_KEY = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;

    uint256 constant PROVISION = 10_000e18; // meets MIN_PROVISION
    uint64  constant THAWING   = 14 days;   // meets MIN_THAWING_PERIOD
    uint256 constant DEPOSIT   = 100_000e18;

    function run() external {
        address deployer      = vm.addr(DEPLOYER_KEY);
        address provider      = vm.addr(PROVIDER_KEY);
        address gateway       = vm.addr(GATEWAY_KEY);
        address gatewaySigner = vm.addr(GATEWAY_SIGN_KEY);
        address pauseGuardian = address(uint160(uint256(keccak256("vince-pause-guardian"))));

        vm.startBroadcast(DEPLOYER_KEY);
        MockGRTToken   grt        = new MockGRTToken();
        ControllerMock controller = new ControllerMock(deployer);
        MockStaking    staking    = new MockStaking();

        controller.setContractProxy(keccak256("GraphToken"),        address(grt));
        controller.setContractProxy(keccak256("Staking"),           address(staking));
        controller.setContractProxy(keccak256("EpochManager"),      address(1));
        controller.setContractProxy(keccak256("RewardsManager"),    address(1));
        controller.setContractProxy(keccak256("GraphTokenGateway"), address(1));
        controller.setContractProxy(keccak256("GraphProxyAdmin"),   address(1));
        controller.setContractProxy(keccak256("Curation"),          address(1));

        uint64 n = vm.getNonce(deployer);
        address predictedPayments = vm.computeCreateAddress(deployer, n + 3);
        address predictedEscrow   = vm.computeCreateAddress(deployer, n + 5);
        controller.setContractProxy(keccak256("GraphPayments"),  predictedPayments);
        controller.setContractProxy(keccak256("PaymentsEscrow"), predictedEscrow);

        GraphPayments payments = GraphPayments(address(new TransparentUpgradeableProxy(
            address(new GraphPayments(address(controller), 0)), address(1),
            abi.encodeCall(GraphPayments.initialize, ())
        )));
        require(address(payments) == predictedPayments, "payments proxy mismatch");

        PaymentsEscrow escrow = PaymentsEscrow(address(new TransparentUpgradeableProxy(
            address(new PaymentsEscrow(address(controller), 0)), address(1),
            abi.encodeCall(PaymentsEscrow.initialize, ())
        )));
        require(address(escrow) == predictedEscrow, "escrow proxy mismatch");

        GraphTallyCollector tally =
            new GraphTallyCollector("GraphTallyCollector", "1", address(controller), 0);

        VinceDataService service =
            new VinceDataService(deployer, address(controller), address(tally), pauseGuardian);

        staking.setProvision(provider, address(service), PROVISION, THAWING);
        vm.stopBroadcast();

        // Provider registers as a Vince-finding operator
        vm.startBroadcast(PROVIDER_KEY);
        service.register(provider, abi.encode("Vince | Nodeify", address(0)));
        vm.stopBroadcast();

        // Provider activates Vince-finding in two regions
        vm.startBroadcast(PROVIDER_KEY);
        service.startService(provider, abi.encode("u120fw", VinceDataService.VinceTier.CONFIRMED));
        service.startService(provider, abi.encode("gbsuv", VinceDataService.VinceTier.SIGHTING));
        vm.stopBroadcast();

        // Gateway authorises signer and funds escrow
        uint256 deadline = block.timestamp + 1 days;
        bytes32 msgHash  = keccak256(abi.encodePacked(block.chainid, address(tally), "authorizeSignerProof", deadline, gateway));
        bytes32 digest   = MessageHashUtils.toEthSignedMessageHash(msgHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(GATEWAY_SIGN_KEY, digest);

        vm.startBroadcast(GATEWAY_KEY);
        tally.authorizeSigner(gatewaySigner, deadline, abi.encodePacked(r, s, v));
        grt.mint(gateway, DEPOSIT);
        grt.approve(address(escrow), DEPOSIT);
        escrow.deposit(address(tally), provider, DEPOSIT);
        vm.stopBroadcast();

        console.log("=== VinceDataService deployed ===");
        console.log("GRT:                ", address(grt));
        console.log("PaymentsEscrow:     ", address(escrow));
        console.log("GraphTallyCollector:", address(tally));
        console.log("VinceDataService:   ", address(service));
        console.log("Provider registered:", service.registeredProviders(provider));
        console.log("Active regions:     ", service.activeRegionCount(provider));
        console.log("Total Vinces located:", service.totalVincesLocated());
        console.log("Escrow funded:      ", grt.balanceOf(address(escrow)));
    }
}
