# Zero To One — Robinhood OFT

`src/ZeroToOne.sol:ZeroToOne` is the Robinhood mint/burn end of the ZTO bridge. It is an ERC-20 named **Zero To One**, symbol **ZTO**, with **18 local decimals**, **6 shared decimals**, and **zero initial supply**. Only messages delivered by the fixed LayerZero V2 endpoint, originating from the fixed Ethereum peer, can persistently mint tokens. Sending burns the caller's tokens; a reverted send restores the burn atomically.

The project is self-contained. Solidity dependencies are vendored as ordinary files under `src/vendor/`; Foundry's test library is under `test/vendor/`. Nothing is required under `lib/` or `node_modules/`. No package installation, network, FFI, environment variables, or filesystem cheatcodes are required by the tests. Foundry and the pinned Solidity compiler must already be available to run offline.

```sh
forge build
forge test
forge fmt --check
```

The compiler is pinned to **0.8.26**, with optimization enabled (200 runs), Paris EVM output, and `bytecode_hash = "none"`. Paris avoids requiring newer EVM opcodes from the target chain. Runtime size and prohibited opcodes are checked in the deployment tests.

## Deployment parameters

Deploy **only `ZeroToOne`**, with **no constructor arguments** and **zero ETH**. `launch.json` describes that application. The other concrete contracts in the vendored sources and test fixtures are dependencies for testing, not launch applications. No deployment script signs or broadcasts transactions.

| Parameter | Fixed value |
| --- | --- |
| Local LayerZero EndpointV2 | `0x6F475642a6e85809B1c36Fa62763669b1b48DD5B` |
| Local LayerZero endpoint ID | `30416` |
| Remote LayerZero endpoint ID | `30101` (Ethereum) |
| Sole remote OFT adapter | `0x68D443f419064B11Cc427B9b72fAA6c1CedF6378` |
| Initial owner and delegate | `0xcECc29B037f5064fCdF45a5C318F132ef76aA551` |
| Local / shared decimals | `18` / `6` |
| Conversion factor | `10^12` local units per shared unit |

These addresses and endpoint IDs come directly from the assignment. They have not been checked against a live RPC or explorer. LayerZero endpoint IDs are **not EVM chain IDs**. `LOCAL_EID` records the intended deployment network; it is not a `block.chainid` guard. The launcher must select and verify the correct chain. A factory can deploy the contract without gaining ownership.

The constructor never queries an external token for metadata. `decimals()` returns the local constant 18. The Ethereum adapter is only a remote identity, never a constructor call target.

The vendored `OAppCore` constructor registers the delegate **only when the fixed endpoint has code**. On a live endpoint, a registration failure propagates and aborts deployment. In a fresh EVM without endpoint code, deployment succeeds with the owner, peer, and metadata already configured. If the endpoint is subsequently installed in that environment, the owner calls `setDelegate(owner)`; calling it while the endpoint still lacks code reverts. There is no token initialization phase. The tests explicitly cover both constructor branches, factory deployment, deferred registration, and failure of a code-bearing endpoint.

## Bridge behavior

The implementation uses LayerZero's OFT V2 send, quote, options, message encoding, receive, compose, and pre-crime simulation interfaces. See the [LayerZero OFT source](https://github.com/LayerZero-Labs/devtools/tree/main/packages/oft-evm) and [composition documentation](https://docs.layerzero.network/v2/developers/evm/oft/oft-patterns-extensions). The exact source versions used here, rather than the moving upstream branch, are recorded in `src/vendor/provenance.json`.

- `token()` is this OFT. `approvalRequired()` is false: `send` burns only `msg.sender`'s tokens and needs no ZTO allowance.
- The peer is installed in the constructor. `setPeer` always rejects changes, including owner attempts to remove the peer or add another chain. Path initialization and simulation peer checks reject unknown chains and empty peers.
- `lzReceive` authenticates the endpoint and the exact `(30101, adapter)` origin. **EndpointV2** verifies committed payload hashes and enforces replay protection. The OFT intentionally does not add a separate nonce or GUID replay table. The endpoint, its configured receive library, and its verification policy are the trust boundary.
- Six shared decimals mean the bridge rounds down to multiples of `10^12` local units. Dust remains with the sender. `minAmountLD` applies after rounding. The default no-fee OFT debits and credits the same rounded amount.
- The wire amount is a `uint64`. The maximum individual send is `(2^64 - 1) * 10^12` local units, or `18,446,744,073,709.551615 ZTO`. Larger sends revert instead of truncating. There is no additional global supply cap. `quoteOFT` retains the upstream advisory total-supply limit; use `quoteSend` to validate an actual route and encoded amount.
- There are **no application fees**. LayerZero transport/execution fees still apply. `quoteSend` obtains them from the endpoint. Native `msg.value` must equal the provided `MessagingFee.nativeFee`; the endpoint refunds excess over its actual charge to the chosen refund address. Optional LZ-token fee payment uses the endpoint's configured token and requires that token's allowance to the OFT.
- Standard compose sends encode the sender and composed payload. Receiving first mints, then queues a separate composition through `sendCompose`. A failure while queueing reverts the receive. A later composed-call failure does not undo the already delivered token credit.
- Standard OFT edge cases remain: a zero inbound recipient credits `address(0xdead)`; a zero or sub-dust send is allowed if `minAmountLD` is zero. Applications should validate recipient addresses and use a positive minimum. `oftCmd` is unused in this default OFT; callers should pass empty bytes.
- Delivery is unordered (`nextNonce` returns zero). Pre-crime simulation always reverts, so it cannot persist a mint.

## Administrative powers and operations

There is no application fee switch, public mint, administrative burn, dedicated pause, upgrade path, rescue, or withdrawal function. The optional message inspector is permanently disabled so an owner cannot install an arbitrary send gate. Token transfers use the normal ERC-20 rules.

The owner retains the standard OApp controls for `setDelegate`, `setEnforcedOptions`, and `setPreCrime`, plus ERC-20-independent ownership transfer and renunciation. Enforced options can change execution costs and liveness. Pre-crime configuration is for simulation; it adds no persistent mint authority. The endpoint delegate can configure the OApp's LayerZero libraries and security settings and use the endpoint's message-management powers, including skip/clear/nilify/burn where applicable. A compromised delegate or insecure verification configuration can therefore defeat bridge security or stop delivery, despite the fixed peer and absence of a token pause function.

Ownership and endpoint delegation are separate. Transferring or renouncing ownership **does not change the registered delegate**. Rotate both deliberately before renouncing ownership; otherwise the old delegate retains endpoint authority while token-level configuration may become inaccessible. `setDelegate(address(0))` follows upstream endpoint semantics and can remove delegation; the constructor always starts with the specified nonzero delegate.

Before users bridge value, the authorized operators must:

1. Verify the target chain, endpoint code and EID, native fee currency, Ethereum adapter identity, underlying token, and compatible OFT message version and six shared decimals. Confirm the adapter actually locks the intended ZTO and can release it on return messages.
2. On Ethereum, configure the adapter's reciprocal peer at EID `30416` to the confirmed deployed Robinhood OFT address. This project cannot configure the remote adapter.
3. Configure and review send/receive libraries, required and optional DVNs, confirmation counts, executor, and timeouts for both directions. The contract does not hardcode those external policies; do not assume endpoint defaults are suitable.
4. Configure appropriate Type 3 enforced receive/compose gas options, and quote transport fees immediately before each send. Start with a small verified round trip before normal operation.
5. Monitor adapter collateral versus issued supply, verified and delivered packets, failed receives, composition queues, fee changes, and owner/delegate configuration changes. Retry failed deliveries through the endpoint with the original authenticated payload. A successful source burn is asynchronous; delayed destination delivery has no local refund or rescue path.
6. Obtain an independent adversarial review and verify the deployed source/bytecode before release. This implementation and its tests are not a security audit or authorization to deploy.

Do not send unrelated ERC-20s or ETH directly to this contract. There is no recovery mechanism, and nonzero native value attached to an inbound receive can remain trapped. Use zero inbound native value for normal token delivery. L2 sequencer availability, censorship, finality, and the external bridge verification system remain operational dependencies; no block-number or timestamp assumptions are embedded in the token.

## Validation and limits

Tests cover empty-EVM CREATE2 deployment, the live delegate branch and deferred branch, constructor failures, immutable configuration, access control, ERC-20 balances/allowances, authenticated minting, wrong caller/peer/chain, unverified and altered messages, replay and re-verification rejection, unordered delivery, malformed payload rollback, simulations, composed messages, dust, slippage, maximum/overflow wire amounts, fees/refunds, failed sends, and refund reentrancy. Fuzz tests check exact shared-decimal credits and receive/send supply conservation.

The messaging fixture uses the **vendored real EndpointV2 implementation**, including its initialized storage, at the specified endpoint address. A test-only message library supplies verification and fixed fees. It does not model DVN signatures, production pricing, a live network, the actual deployed endpoint bytecode, or the Ethereum adapter's collateral. No fork, environment secrets, or shared external state are used. The protected harness's runtime-size/opcode constraints are also rehearsed locally without its environment-variable inputs. Foundry checks and fuzzing ran; Slither, Mythril, a live-chain fork, and an independent audit did not.
