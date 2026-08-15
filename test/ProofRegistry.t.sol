// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ProofRegistry} from "../src/ProofRegistry.sol";

contract ProofRegistryTest is Test {
    ProofRegistry internal registry;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    bytes32 internal constant ROOT_A = keccak256("root-a");
    bytes32 internal constant ROOT_B = keccak256("root-b");

    function setUp() public {
        vm.warp(1_800_000_000);
        registry = new ProofRegistry();
    }

    function test_AnchorStoresTheRootUnderTheCallersAccount() public {
        uint64 epoch = registry.currentEpoch();

        vm.prank(alice);
        registry.anchor(epoch, ROOT_A);

        assertEq(registry.rootAt(alice, epoch), ROOT_A);
        assertEq(registry.latestEpoch(alice), epoch);
        assertEq(registry.rootAt(bob, epoch), bytes32(0));
    }

    function test_AccountsAreIsolated() public {
        uint64 epoch = registry.currentEpoch();

        vm.prank(alice);
        registry.anchor(epoch, ROOT_A);
        vm.prank(bob);
        registry.anchor(epoch, ROOT_B);

        assertEq(registry.rootAt(alice, epoch), ROOT_A);
        assertEq(registry.rootAt(bob, epoch), ROOT_B);
    }

    // Re-anchoring within an epoch is expected: the vault changes during the day.
    function test_ReanchoringWithinAnEpochOverwrites() public {
        uint64 epoch = registry.currentEpoch();

        vm.startPrank(alice);
        registry.anchor(epoch, ROOT_A);
        registry.anchor(epoch, ROOT_B);
        vm.stopPrank();

        assertEq(registry.rootAt(alice, epoch), ROOT_B);
    }

    function test_HistoryIsPreservedAcrossEpochs() public {
        uint64 first = registry.currentEpoch();

        vm.prank(alice);
        registry.anchor(first, ROOT_A);

        vm.warp(block.timestamp + 2 days);
        uint64 later = registry.currentEpoch();

        vm.prank(alice);
        registry.anchor(later, ROOT_B);

        assertEq(registry.rootAt(alice, first), ROOT_A, "an older anchor must remain provable");
        assertEq(registry.rootAt(alice, later), ROOT_B);

        (uint64 epoch, bytes32 root) = registry.latestRoot(alice);
        assertEq(epoch, later);
        assertEq(root, ROOT_B);
    }

    // The guarantee the registry exists to provide: once an epoch closes, the
    // root recorded for it can never be restated. An heir holding a valid
    // inclusion proof against it cannot have that proof invalidated later.
    function test_RewritingAnOccupiedPastEpochIsRejected() public {
        uint64 first = registry.currentEpoch();

        vm.prank(alice);
        registry.anchor(first, ROOT_A);

        vm.warp(block.timestamp + 1 days);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ProofRegistry.EpochAlreadyAnchored.selector, first, ROOT_A));
        registry.anchor(first, ROOT_B);

        assertEq(registry.rootAt(alice, first), ROOT_A, "a closed epoch must keep its original root");
    }

    // Re-submitting the identical root is rejected too. Nothing in the product
    // needs it, and an exemption would be a second write path into closed
    // history to reason about.
    function test_RewritingAnOccupiedPastEpochIsRejectedEvenWithTheSameRoot() public {
        uint64 first = registry.currentEpoch();

        vm.prank(alice);
        registry.anchor(first, ROOT_A);

        vm.warp(block.timestamp + 3 days);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ProofRegistry.EpochAlreadyAnchored.selector, first, ROOT_A));
        registry.anchor(first, ROOT_A);
    }

    // Today's root is still mutable, and stops being so at midnight.
    function test_TodaysRootFreezesWhenItsEpochCloses() public {
        uint64 today = registry.currentEpoch();

        vm.startPrank(alice);
        registry.anchor(today, ROOT_A);
        registry.anchor(today, ROOT_B);
        vm.stopPrank();

        assertEq(registry.rootAt(alice, today), ROOT_B);

        vm.warp(block.timestamp + 1 days);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ProofRegistry.EpochAlreadyAnchored.selector, today, ROOT_B));
        registry.anchor(today, keccak256("too-late"));
    }

    // Writing an epoch that was never used is not a rewrite, and the client
    // depends on it: an anchor submitted at 23:59 can be mined after midnight.
    function test_BackfillingAnEmptyPastEpochIsAllowed() public {
        uint64 first = registry.currentEpoch();

        vm.prank(alice);
        registry.anchor(first, ROOT_A);

        vm.warp(block.timestamp + 4 days);

        vm.prank(alice);
        registry.anchor(first + 2, ROOT_B);

        assertEq(registry.rootAt(alice, first + 2), ROOT_B);
        assertEq(registry.rootAt(alice, first), ROOT_A);
    }

    function test_FreezingIsPerAccount() public {
        uint64 first = registry.currentEpoch();

        vm.prank(alice);
        registry.anchor(first, ROOT_A);

        vm.warp(block.timestamp + 1 days);

        vm.prank(bob);
        registry.anchor(first, ROOT_B);

        assertEq(registry.rootAt(alice, first), ROOT_A);
        assertEq(registry.rootAt(bob, first), ROOT_B);
    }

    function testFuzz_AClosedEpochNeverChanges(bytes32 attempt, uint8 daysLater) public {
        vm.assume(attempt != bytes32(0));
        uint64 first = registry.currentEpoch();

        vm.prank(alice);
        registry.anchor(first, ROOT_A);

        vm.warp(block.timestamp + (uint256(daysLater) + 1) * 1 days);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ProofRegistry.EpochAlreadyAnchored.selector, first, ROOT_A));
        registry.anchor(first, attempt);

        assertEq(registry.rootAt(alice, first), ROOT_A);
    }

    function test_BackdatedAnchorDoesNotMoveTheLatestPointer() public {
        uint64 first = registry.currentEpoch();
        vm.prank(alice);
        registry.anchor(first, ROOT_A);

        vm.warp(block.timestamp + 5 days);
        uint64 later = registry.currentEpoch();
        vm.prank(alice);
        registry.anchor(later, ROOT_B);

        vm.prank(alice);
        registry.anchor(first + 1, keccak256("backfill"));

        assertEq(registry.latestEpoch(alice), later);
    }

    function test_FutureEpochIsRejected() public {
        uint64 current = registry.currentEpoch();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ProofRegistry.EpochInTheFuture.selector, current + 1, current));
        registry.anchor(current + 1, ROOT_A);
    }

    function test_EmptyRootIsRejected() public {
        uint64 epoch = registry.currentEpoch();

        vm.prank(alice);
        vm.expectRevert(ProofRegistry.EmptyRoot.selector);
        registry.anchor(epoch, bytes32(0));
    }

    function test_EpochIsDailyAndDerivedFromTimestamp() public {
        assertEq(registry.currentEpoch(), uint64(block.timestamp) / 86400);

        uint64 before = registry.currentEpoch();
        vm.warp(block.timestamp + 86400);
        assertEq(registry.currentEpoch(), before + 1);
    }

    function testFuzz_AnyoneCanAnchorOnlyTheirOwnAccount(address caller, bytes32 root) public {
        vm.assume(caller != address(0));
        vm.assume(root != bytes32(0));

        uint64 epoch = registry.currentEpoch();
        vm.prank(caller);
        registry.anchor(epoch, root);

        assertEq(registry.rootAt(caller, epoch), root);
    }
}
