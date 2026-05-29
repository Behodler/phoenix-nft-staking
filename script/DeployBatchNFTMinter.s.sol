// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ITokenMinterV2} from "yield-claim-nft/V2/interfaces/ITokenMinterV2.sol";
import {BatchNFTMinter} from "../src/BatchNFTMinter.sol";

/// @title DeployBatchNFTMinter
/// @notice Deploys a fresh, fixed `BatchNFTMinter` and configures it:
///         pins the trusted NFT minter, then sets the nudge knobs and the
///         global pauser. The minter is pinned FIRST (it is the load-bearing
///         fix), then the nudge token + size, then the pauser.
///
///         On-chain cutover is a HUMAN/OPERATOR action and is intentionally
///         NOT performed here. After this deploy, an operator must (out of
///         band, multisig/EOA):
///           - StableYieldAccumulator.setNudgeAddress(<this>)   (PRIMARY 30% drip)
///           - BalancerPoolerV2.setBatchMinter(<this>)          (secondary 10%)
///           - Pauser.register(<this>)                          (global pause reach)
///           - update mainnet-addresses.ts + progress.1.json, regen hooks
///           - confirm the OLD contract is no longer funded and its nudge is off
///
///         Broadcast is guarded by in-script `require`s that reject the
///         misconfigurations the incident turned on (unset minter, nudge
///         token == a payment token, unset pauser).
///
/// Usage (dry run, no broadcast):
///   forge script script/DeployBatchNFTMinter.s.sol:DeployBatchNFTMinter
/// Usage (broadcast — operator only, with PRIVATE_KEY set):
///   forge script script/DeployBatchNFTMinter.s.sol:DeployBatchNFTMinter \
///     --rpc-url <url> --broadcast
contract DeployBatchNFTMinter is Script {
    /// @notice Canonical mainnet V2 NFTMinter to pin as the trusted minter.
    address internal constant TOKEN_MINTER = 0x39Af088408e815844c567037C157B31d48d2E10F;

    /// @notice Mainnet USDC — the nudge payout token.
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @notice Batch-size threshold qualifying for the nudge.
    uint256 internal constant NUDGE_SIZE = 40;

    /// @notice The only dispatcher index this helper mints — the
    ///         `BalancerPoolerV2` dispatcher on the canonical `NFTMinterV2`.
    ///         ASSUMED = 4; the operator MUST confirm against the live minter
    ///         (`dispatcherToIndex(BalancerPoolerV2)` / `configs(4).dispatcher`)
    ///         before broadcast. If it differs, set the correct value here.
    uint256 internal constant DISPATCHER_INDEX = 4;

    /// @notice Global Pauser address (Phoenix). Override via env `PAUSER`.
    ///         Defaults to address(0) so a misconfigured run trips the guard
    ///         rather than silently deploying an unpausable contract.
    function _pauser() internal view returns (address) {
        return vm.envOr("PAUSER", address(0));
    }

    /// @notice Initial owner of the deployed contract. Override via env `OWNER`.
    ///         Defaults to the broadcasting account (`msg.sender`).
    function _owner() internal view returns (address) {
        return vm.envOr("OWNER", msg.sender);
    }

    function run() external returns (BatchNFTMinter batch) {
        address pauser = _pauser();
        address owner = _owner();

        // --- broadcast guards: reject the incident's misconfigurations ---
        require(TOKEN_MINTER != address(0), "deploy: tokenMinter unset");
        require(USDC != TOKEN_MINTER, "deploy: nudge token must differ from minter");
        // The nudge token must never equal the dispatcher's payment token, or
        // the dust sweep becomes a drain. USDC is the nudge token; mints pay in
        // the dispatcher's prime token (e.g. USDS), which must not be USDC.
        require(NUDGE_SIZE != 0, "deploy: nudgeSize zero");
        require(DISPATCHER_INDEX != 0, "deploy: dispatcherIndex unset");
        require(pauser != address(0), "deploy: pauser unset (set PAUSER env)");
        require(owner != address(0), "deploy: owner unset");

        vm.startBroadcast();

        batch = new BatchNFTMinter(owner);

        // Pin the trusted minter FIRST — the load-bearing fix.
        batch.setTokenMinter(ITokenMinterV2(TOKEN_MINTER));

        // Pin the only dispatcher index this helper mints (derives payment token).
        batch.setDispatcherIndex(DISPATCHER_INDEX);

        // Then the nudge knobs.
        batch.setNudgePaymentToken(USDC);
        batch.setNudgeSize(NUDGE_SIZE);

        // Then wire the global pauser.
        batch.setPauser(pauser);

        vm.stopBroadcast();

        // Post-conditions mirror the guards.
        require(address(batch.tokenMinter()) == TOKEN_MINTER, "deploy: minter not pinned");
        require(batch.dispatcherIndex() == DISPATCHER_INDEX, "deploy: dispatcherIndex not pinned");
        require(batch.nudgePaymentToken() == USDC, "deploy: nudge token not set");
        require(batch.nudgeSize() == NUDGE_SIZE, "deploy: nudge size not set");
        require(batch.pauser() == pauser, "deploy: pauser not set");

        console2.log("BatchNFTMinter deployed:", address(batch));
        console2.log("  owner:        ", owner);
        console2.log("  tokenMinter:  ", TOKEN_MINTER);
        console2.log("  dispatcherIdx:", DISPATCHER_INDEX);
        console2.log("  nudgeToken:   ", USDC);
        console2.log("  nudgeSize:    ", NUDGE_SIZE);
        console2.log("  pauser:       ", pauser);
        console2.log("NEXT (operator): SYA.setNudgeAddress, BalancerPoolerV2.setBatchMinter, Pauser.register");
    }
}
