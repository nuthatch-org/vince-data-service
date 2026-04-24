# vince-data-service

A real [Horizon](https://thegraph.com/docs/horizon) data service for locating individuals named Vince, worldwide.

Inspired by the legendary [Josh Fight](https://en.wikipedia.org/wiki/Josh_fight) and the visionary question posed in The Graph Discord:

> "When @Vince | Nodeify data service? (Find all Vince worldwide)"

This is a fully functional Horizon data service. It compiles. It deploys. It moves GRT. The Vinces are not real. The payments are.

## What's in here

| File | Purpose |
|---|---|
| `src/VinceDataService.sol` | The contract — VinceTier enum, region tracking, `totalVincesLocated` counter, collect(), slash() reverts |
| `script/Deploy.s.sol` | Foundry deploy script — full Horizon stack + VinceDataService + provider registration + two active regions + escrow funding |
| `remappings.txt` | Working remappings for the `graphprotocol/contracts` package |
| `foundry.toml` | Project config — includes `via_ir = true` |

## The contract

```solidity
contract VinceDataService is Ownable, DataService, DataServiceFees, DataServicePausable
```

Providers register and activate coverage for geographic regions (identified by geohash) at one of three tiers:

```solidity
enum VinceTier {
    SIGHTING,   // unconfirmed Vince sighting; provider says "there's a Vince around here somewhere"
    CONFIRMED,  // verified Vince presence; provider has made eye contact
    WORLDWIDE   // global Vince network; provider has eyes on all Vinces at all times
}
```

On every successful `collect()`, the contract increments `totalVincesLocated` — a conservative estimate that counts each GRT wei of fees as one Vince located. This is not accurate. It is on-chain. It is permanent.

Slashing is not supported:

```solidity
function slash(address, bytes calldata) external pure override {
    // Vince is a lover, not a fighter.
    // See also: https://en.wikipedia.org/wiki/Josh_fight
    revert("Vince does not slash");
}
```

## Prerequisites

- [Foundry](https://getfoundry.sh/) — `curl -L https://foundry.paradigm.xyz | bash && foundryup`

## Setup

Clone and install dependencies:

```bash
git clone https://github.com/cargopete/vince-data-service
cd vince-data-service
forge install graphprotocol/contracts
forge install OpenZeppelin/openzeppelin-contracts
forge install OpenZeppelin/openzeppelin-contracts-upgradeable
forge install foundry-rs/forge-std
```

Compile:

```bash
forge build
```

## Run locally

Start Anvil:

```bash
anvil --chain-id 412346 --block-time 1 --accounts 10
```

Deploy the full stack:

```bash
forge script script/Deploy.s.sol:Deploy \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast \
  --skip-simulation
```

Expected output:

```
=== VinceDataService deployed ===
GRT:                 0x...
PaymentsEscrow:      0x...
GraphTallyCollector: 0x...
VinceDataService:    0x...
Provider registered: true
Active regions:      2
Total Vinces located: 0
Escrow funded:       100000000000000000000000
```

## Verify the lifecycle

```bash
SERVICE=<address from deploy output>
PROVIDER=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
PROVIDER_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
RPC=http://127.0.0.1:8545

# Check registration
cast call $SERVICE "registeredProviders(address)(bool)" $PROVIDER --rpc-url $RPC

# List active regions (geohash, tier, active)
cast call $SERVICE "getRegions(address)((string,uint8,bool)[])" $PROVIDER --rpc-url $RPC

# Activate a new region (WORLDWIDE tier)
DATA=$(cast abi-encode "f(string,uint8)" "gcpvj" 2)
cast send $SERVICE "startService(address,bytes)" $PROVIDER $DATA \
  --rpc-url $RPC --private-key $PROVIDER_KEY

# Stop a region (by index)
cast send $SERVICE "stopService(address,bytes)" $PROVIDER \
  $(cast abi-encode "f(uint256)" 0) \
  --rpc-url $RPC --private-key $PROVIDER_KEY

# Attempt slash (will revert)
cast send $SERVICE "slash(address,bytes)" $PROVIDER "0x" \
  --rpc-url $RPC --private-key $PROVIDER_KEY
```

## Further reading

- [How to Build a Horizon Data Service](https://www.lodestar-dashboard.com/blog/how-to-build-a-horizon-data-service) — the guide this was built from
- [hello-data-service](https://github.com/cargopete/hello-data-service) — minimal reference implementation
- [SubgraphService](https://github.com/graphprotocol/contracts/tree/main/packages/subgraph-service) — reference implementation from The Graph core team
- [GIP-0066: Horizon](https://forum.thegraph.com/t/gip-0066-introducing-graph-horizon-a-data-services-protocol/5989)

## License

Apache-2.0
