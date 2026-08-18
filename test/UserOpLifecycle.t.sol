// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {
    ERC7579Utils,
    Mode,
    CallType,
    ExecType,
    ModeSelector,
    ModePayload
} from "@openzeppelin/contracts/account/utils/draft-ERC7579Utils.sol";
import {Execution} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {IERC7821} from "@openzeppelin/contracts/interfaces/draft-IERC7821.sol";
import {P256Account} from "p256-account/P256Account.sol";
import {P256AccountFactory} from "p256-account/P256AccountFactory.sol";
import {DeadManSwitch} from "../src/DeadManSwitch.sol";
import {ProofRegistry} from "../src/ProofRegistry.sol";

// The keystone of the architecture, end to end: the P-256 key derived from a
// user's seed phrase signs an ERC-4337 UserOperation, the EntryPoint validates
// it through the RIP-7212 precompile, and the resulting call reaches
// DeadManSwitch as msg.sender == the user's own account.
//
// This is what proves the claim that a user checks in with no wallet, no
// extension, no ETH and no second curve.
contract UserOpLifecycleTest is Test {
    EntryPoint internal entryPoint;
    P256AccountFactory internal factory;
    P256Account internal account;
    DeadManSwitch internal dms;
    ProofRegistry internal registry;

    // Stands in for the key at m/9027'/0'/0' of a real seed phrase.
    uint256 internal constant PEDRO_KEY = uint256(keccak256("pedro-seed-p256"));
    uint256 internal constant ATTACKER_KEY = uint256(keccak256("attacker-p256"));

    uint32 internal constant MIN_INACTIVITY = 5 minutes;
    uint32 internal constant MIN_CONTEST = 2 minutes;

    uint32 internal constant INACTIVITY = 180 days;
    uint32 internal constant CONTEST = 7 days;

    address internal constant CANONICAL_ENTRYPOINT = 0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108;

    uint256 internal constant N = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551;
    uint256 internal constant HALF_N = 0x7fffffff800000007fffffffffffffffde737d56d38bcf4279dce5617e3192a8;

    address internal bundler = makeAddr("bundler");
    address internal heir = makeAddr("heir");

    function setUp() public {
        vm.warp(1_800_000_000);

        // The account hardcodes the canonical EntryPoint address, so the test must
        // put a real one there — constructor included, or its reentrancy guard
        // starts in an invalid state.
        deployCodeTo("EntryPoint.sol:EntryPoint", CANONICAL_ENTRYPOINT);
        entryPoint = EntryPoint(payable(CANONICAL_ENTRYPOINT));

        factory = new P256AccountFactory();
        dms = new DeadManSwitch(MIN_INACTIVITY, MIN_CONTEST);
        registry = new ProofRegistry();

        (uint256 qx, uint256 qy) = vm.publicKeyP256(PEDRO_KEY);
        account = P256Account(payable(factory.createAccount(bytes32(qx), bytes32(qy), bytes32(0), 0, 0, bytes32(0))));

        // In production a paymaster sponsors this; here the account prefunds itself.
        vm.deal(address(account), 10 ether);
        vm.prank(address(account));
        entryPoint.depositTo{value: 5 ether}(address(account));
    }

    function test_TheAccountAddressIsDerivedFromTheSeedKeyAlone() public view {
        (uint256 qx, uint256 qy) = vm.publicKeyP256(PEDRO_KEY);
        assertEq(factory.getAddress(bytes32(qx), bytes32(qy), bytes32(0), 0, 0, bytes32(0)), address(account));
    }

    function test_ConfigureAndCheckInThroughTheEntryPoint() public {
        _send(abi.encodeCall(DeadManSwitch.configure, (INACTIVITY, CONTEST, bytes32(0), 0)), PEDRO_KEY);

        DeadManSwitch.Record memory record = dms.recordOf(address(account));
        assertEq(uint8(record.status), uint8(DeadManSwitch.Status.Active));
        assertEq(record.lastCheckIn, uint64(block.timestamp));

        vm.warp(block.timestamp + 90 days);
        _send(abi.encodeCall(DeadManSwitch.checkIn, ()), PEDRO_KEY);

        assertEq(dms.recordOf(address(account)).lastCheckIn, uint64(block.timestamp));
        assertEq(dms.triggerableAt(address(account)), uint64(block.timestamp) + INACTIVITY);
    }

    // The invariant the trust model rests on, proved at the signature layer:
    // a userOp not signed by the account's own key never reaches the switch.
    function test_ForeignKeyCannotCheckIn() public {
        _send(abi.encodeCall(DeadManSwitch.configure, (INACTIVITY, CONTEST, bytes32(0), 0)), PEDRO_KEY);
        uint64 checkedInAt = dms.recordOf(address(account)).lastCheckIn;

        vm.warp(block.timestamp + 90 days);

        PackedUserOperation memory op = _build(abi.encodeCall(DeadManSwitch.checkIn, ()));
        op.signature = _sign(ATTACKER_KEY, entryPoint.getUserOpHash(op));

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;

        // Two-argument prank: the EntryPoint's guard requires tx.origin == msg.sender,
        // so the bundler must look like a real externally owned account.
        vm.prank(bundler, bundler);
        vm.expectRevert();
        entryPoint.handleOps(ops, payable(bundler));

        assertEq(dms.recordOf(address(account)).lastCheckIn, checkedInAt, "an unsigned check-in must not land");
    }

    function test_FullReleaseLifecycleWithRealUserOps() public {
        _send(abi.encodeCall(DeadManSwitch.configure, (INACTIVITY, CONTEST, bytes32(0), 0)), PEDRO_KEY);

        // 180 days of silence. Nothing fires on its own: someone has to call trigger.
        vm.warp(block.timestamp + INACTIVITY + 1);
        vm.prank(heir);
        dms.trigger(address(account));
        assertEq(uint8(dms.statusOf(address(account))), uint8(DeadManSwitch.Status.Contest));

        vm.warp(dms.releasableAt(address(account)) + 1);
        vm.prank(heir);
        dms.finalize(address(account));

        assertTrue(dms.isReleased(address(account)));
    }

    // Revocation, driven the way a live owner actually drives it.
    function test_CheckInDuringContestRevokesThroughTheEntryPoint() public {
        _send(abi.encodeCall(DeadManSwitch.configure, (INACTIVITY, CONTEST, bytes32(0), 0)), PEDRO_KEY);

        vm.warp(block.timestamp + INACTIVITY + 1);
        vm.prank(heir);
        dms.trigger(address(account));

        _send(abi.encodeCall(DeadManSwitch.checkIn, ()), PEDRO_KEY);

        assertEq(uint8(dms.statusOf(address(account))), uint8(DeadManSwitch.Status.Active));

        vm.warp(block.timestamp + CONTEST + 1);
        vm.prank(heir);
        vm.expectRevert(DeadManSwitch.NotContesting.selector);
        dms.finalize(address(account));
    }

    function test_AnchorThroughTheEntryPoint() public {
        bytes32 root = keccak256("vault-root");
        uint64 epoch = registry.currentEpoch();

        _sendTo(address(registry), abi.encodeCall(ProofRegistry.anchor, (epoch, root)), PEDRO_KEY);

        assertEq(registry.rootAt(address(account), epoch), root, "the anchor must be attributed to the account");
    }

    function _send(bytes memory innerCall, uint256 key) private {
        _sendTo(address(dms), innerCall, key);
    }

    function _sendTo(address target, bytes memory innerCall, uint256 key) private {
        PackedUserOperation memory op = _buildTo(target, innerCall);
        op.signature = _sign(key, entryPoint.getUserOpHash(op));

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;

        vm.prank(bundler, bundler);
        entryPoint.handleOps(ops, payable(bundler));
    }

    function _build(bytes memory innerCall) private view returns (PackedUserOperation memory) {
        return _buildTo(address(dms), innerCall);
    }

    function _buildTo(address target, bytes memory innerCall) private view returns (PackedUserOperation memory) {
        Execution[] memory batch = new Execution[](1);
        batch[0] = Execution({target: target, value: 0, callData: innerCall});

        bytes32 mode = Mode.unwrap(
            ERC7579Utils.encodeMode(
                ERC7579Utils.CALLTYPE_BATCH,
                ERC7579Utils.EXECTYPE_DEFAULT,
                ModeSelector.wrap(0x00000000),
                ModePayload.wrap(0x00000000000000000000000000000000000000000000)
            )
        );

        return PackedUserOperation({
            sender: address(account),
            nonce: entryPoint.getNonce(address(account), 0),
            initCode: "",
            callData: abi.encodeCall(IERC7821.execute, (mode, ERC7579Utils.encodeBatch(batch))),
            accountGasLimits: bytes32((uint256(1_000_000) << 128) | uint256(1_000_000)),
            preVerificationGas: 100_000,
            gasFees: bytes32((uint256(1 gwei) << 128) | uint256(1 gwei)),
            paymasterAndData: "",
            signature: ""
        });
    }

    // Web Crypto and noble emit low-`s`; OpenZeppelin's P256.verify requires it.
    function _sign(uint256 key, bytes32 digest) private pure returns (bytes memory) {
        (bytes32 r, bytes32 s) = vm.signP256(key, digest);
        if (uint256(s) > HALF_N) {
            s = bytes32(N - uint256(s));
        }
        return abi.encodePacked(r, s);
    }
}
