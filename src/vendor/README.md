# Vendored Solidity dependencies

Only Solidity import closures and package/license metadata are included. Build and test do not run npm or fetch packages.

| Package | Version | Role |
| --- | --- | --- |
| `@layerzerolabs/oft-evm` | `4.0.1` | OFT, codecs, interfaces |
| `@layerzerolabs/oapp-evm` | `0.4.1` | OApp, Type 3 options, pre-crime simulation |
| `@layerzerolabs/lz-evm-protocol-v2` | `3.0.148` | Endpoint interfaces and upstream endpoint for integration tests |
| `@openzeppelin/contracts` | `4.9.6` | ERC-20, Ownable, SafeERC20, required utilities |

`provenance.json` records the exact npm tarballs and verified SHA-512 integrity values. `license-sources.json` records the upstream locations used for license texts omitted from npm archives. Per-file SPDX notices remain intact. LayerZero protocol implementation files are LZBL-1.2; its MIT interfaces and the MIT OFT/OApp code keep their respective license notices. The application does not deploy a copy of the protocol endpoint. OpenZeppelin 4.9.6 is within these LayerZero packages' declared compatible range; application ownership is explicitly transferred in `ZeroToOne`'s constructor.

There is **one source modification** in the vendored closure:

```diff
--- @layerzerolabs/oapp-evm/contracts/oapp/OAppCore.sol
+++ local
@@ constructor
-        endpoint.setDelegate(_delegate);
+        // Local adaptation: fresh-EVM launch rehearsals have no endpoint code.
+        // A live endpoint must still register the delegate during construction.
+        if (_endpoint.code.length > 0) endpoint.setDelegate(_delegate);
```

`setDelegate` remains the upstream owner-only method. No error from a live endpoint is swallowed. Peer freezing, constant local decimals, strict path initialization, and disabling the optional message inspector are implemented in `src/ZeroToOne.sol`, outside the vendored sources. The OFT constructor calls the token's internal `decimals()` implementation, not an external metadata contract.

Protocol files beyond the application's import closure are included to test against EndpointV2 itself. They are not application deployment targets. Forge-std `v1.9.7` is separately vendored under `test/vendor/forge-std`, including licenses and archive provenance. No submodules are used. Vendor formatting is preserved and excluded from `forge fmt`.
