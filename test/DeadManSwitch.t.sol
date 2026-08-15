// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {DeadManSwitch} from "../src/DeadManSwitch.sol";

contract DeadManSwitchTest is Test {
    DeadManSwitch internal dms;

    uint32 internal constant MIN_INACTIVITY = 1 days;
    uint32 internal constant MIN_CONTEST = 1 hours;

    uint32 internal constant INACTIVITY = 30 days;
    uint32 internal constant CONTEST = 7 days;

    address internal owner = makeAddr("owner");
    address internal heir = makeAddr("heir");
    address internal guardian = makeAddr("guardian");
    address internal stranger = makeAddr("stranger");

    bytes32 internal constant GUARDIAN_ROOT = keccak256("guardian-set");

    function setUp() public {
        vm.warp(1_800_000_000);
        dms = new DeadManSwitch(MIN_INACTIVITY, MIN_CONTEST);

        vm.prank(owner);
        dms.configure(INACTIVITY, CONTEST, GUARDIAN_ROOT, 2);
    }

    function test_ConfigureStartsTheClock() public view {
        DeadManSwitch.Record memory record = dms.recordOf(owner);
        assertEq(uint8(record.status), uint8(DeadManSwitch.Status.Active));
        assertEq(record.lastCheckIn, uint64(block.timestamp));
        assertEq(record.inactivityPeriod, INACTIVITY);
        assertEq(record.contestPeriod, CONTEST);
        assertEq(record.guardianRoot, GUARDIAN_ROOT);
        assertEq(dms.triggerableAt(owner), uint64(block.timestamp) + INACTIVITY);
    }

    function test_FullLifecycleToRelease() public {
        vm.warp(block.timestamp + INACTIVITY + 1);

        vm.prank(heir);
        dms.trigger(owner);
        assertEq(uint8(dms.statusOf(owner)), uint8(DeadManSwitch.Status.Contest));

        vm.warp(dms.releasableAt(owner) + 1);

        vm.prank(heir);
        dms.finalize(owner);
        assertTrue(dms.isReleased(owner));
    }

    // The revocation path: a live owner who checks in during Contest stops the release.
    function test_CheckInDuringContestRevokes() public {
        vm.warp(block.timestamp + INACTIVITY + 1);
        vm.prank(stranger);
        dms.trigger(owner);

        vm.prank(owner);
        dms.checkIn();

        DeadManSwitch.Record memory record = dms.recordOf(owner);
        assertEq(uint8(record.status), uint8(DeadManSwitch.Status.Active));
        assertEq(record.triggeredAt, 0);
        assertEq(record.lastCheckIn, uint64(block.timestamp));

        vm.warp(block.timestamp + CONTEST + 1);
        vm.expectRevert(DeadManSwitch.NotContesting.selector);
        dms.finalize(owner);
    }

    // The invariant the whole trust model rests on: nobody but the account may check in.
    function test_OnlyTheOwnerCanCheckIn() public {
        vm.warp(block.timestamp + 10 days);

        vm.prank(stranger);
        vm.expectRevert(DeadManSwitch.NotConfigured.selector);
        dms.checkIn();

        DeadManSwitch.Record memory record = dms.recordOf(owner);
        assertEq(record.lastCheckIn, uint64(block.timestamp) - 10 days);
    }

    function test_TriggerBeforeTheDeadlineReverts() public {
        vm.warp(block.timestamp + INACTIVITY - 1);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeadManSwitch.DeadlineNotReached.selector, uint64(block.timestamp), dms.triggerableAt(owner)
            )
        );
        dms.trigger(owner);
    }

    function test_FinalizeBeforeTheContestPeriodEndsReverts() public {
        vm.warp(block.timestamp + INACTIVITY + 1);
        dms.trigger(owner);

        uint64 deadline = dms.releasableAt(owner);
        vm.warp(deadline);

        vm.expectRevert(
            abi.encodeWithSelector(DeadManSwitch.DeadlineNotReached.selector, uint64(block.timestamp), deadline)
        );
        dms.finalize(owner);
    }

    // Anyone may advance a genuinely expired record: Cryple disappearing must not
    // freeze the switch.
    function test_TriggerAndFinalizeArePermissionless() public {
        vm.warp(block.timestamp + INACTIVITY + 1);

        vm.prank(guardian);
        dms.trigger(owner);

        vm.warp(dms.releasableAt(owner) + 1);

        vm.prank(stranger);
        dms.finalize(owner);

        assertTrue(dms.isReleased(owner));
    }

    function test_DoubleTriggerAndDoubleFinalizeRevert() public {
        vm.warp(block.timestamp + INACTIVITY + 1);
        dms.trigger(owner);

        vm.expectRevert(DeadManSwitch.NotActive.selector);
        dms.trigger(owner);

        vm.warp(dms.releasableAt(owner) + 1);
        dms.finalize(owner);

        vm.expectRevert(DeadManSwitch.NotContesting.selector);
        dms.finalize(owner);
    }

    function test_ReleasedIsTerminal() public {
        vm.warp(block.timestamp + INACTIVITY + 1);
        dms.trigger(owner);
        vm.warp(dms.releasableAt(owner) + 1);
        dms.finalize(owner);

        vm.prank(owner);
        vm.expectRevert(DeadManSwitch.AlreadyReleased.selector);
        dms.checkIn();

        vm.prank(owner);
        vm.expectRevert(DeadManSwitch.AlreadyReleased.selector);
        dms.configure(INACTIVITY, CONTEST, GUARDIAN_ROOT, 2);
    }

    function test_MinimumPeriodsAreEnforced() public {
        vm.startPrank(stranger);

        vm.expectRevert(
            abi.encodeWithSelector(DeadManSwitch.PeriodTooShort.selector, MIN_INACTIVITY - 1, MIN_INACTIVITY)
        );
        dms.configure(MIN_INACTIVITY - 1, CONTEST, bytes32(0), 0);

        vm.expectRevert(abi.encodeWithSelector(DeadManSwitch.PeriodTooShort.selector, MIN_CONTEST - 1, MIN_CONTEST));
        dms.configure(INACTIVITY, MIN_CONTEST - 1, bytes32(0), 0);

        vm.stopPrank();
    }

    function test_GuardianConfigMustBeCoherent() public {
        vm.startPrank(stranger);

        vm.expectRevert(DeadManSwitch.InvalidGuardianConfig.selector);
        dms.configure(INACTIVITY, CONTEST, bytes32(0), 2);

        vm.expectRevert(DeadManSwitch.InvalidGuardianConfig.selector);
        dms.configure(INACTIVITY, CONTEST, GUARDIAN_ROOT, 0);

        vm.stopPrank();
    }

    function test_ReconfiguringRefreshesTheDeadline() public {
        vm.warp(block.timestamp + 20 days);

        vm.prank(owner);
        dms.configure(INACTIVITY, CONTEST, GUARDIAN_ROOT, 2);

        assertEq(dms.triggerableAt(owner), uint64(block.timestamp) + INACTIVITY);
    }

    function test_UnconfiguredRecordCannotBeTriggered() public {
        vm.expectRevert(DeadManSwitch.NotActive.selector);
        dms.trigger(stranger);
    }

    // Privacy rule: no guardian or heir address may appear in any event payload.
    function test_EventsCarryNoGuardianOrHeirAddress() public {
        vm.recordLogs();

        vm.warp(block.timestamp + INACTIVITY + 1);
        vm.prank(guardian);
        dms.trigger(owner);
        vm.warp(dms.releasableAt(owner) + 1);
        vm.prank(heir);
        dms.finalize(owner);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertGt(logs.length, 0);

        bytes32 guardianWord = bytes32(uint256(uint160(guardian)));
        bytes32 heirWord = bytes32(uint256(uint160(heir)));

        for (uint256 i = 0; i < logs.length; i++) {
            for (uint256 t = 0; t < logs[i].topics.length; t++) {
                assertTrue(logs[i].topics[t] != guardianWord, "guardian address leaked in a topic");
                assertTrue(logs[i].topics[t] != heirWord, "heir address leaked in a topic");
            }
            assertEq(_contains(logs[i].data, guardianWord), false, "guardian address leaked in event data");
            assertEq(_contains(logs[i].data, heirWord), false, "heir address leaked in event data");
        }
    }

    function testFuzz_NeverReleasesEarly(uint32 inactivity, uint32 contest, uint64 elapsed) public {
        inactivity = uint32(bound(inactivity, MIN_INACTIVITY, 365 days));
        contest = uint32(bound(contest, MIN_CONTEST, 90 days));
        elapsed = uint64(bound(elapsed, 0, uint64(inactivity) + uint64(contest)));

        address subject = makeAddr("fuzz-subject");
        vm.prank(subject);
        dms.configure(inactivity, contest, bytes32(0), 0);

        uint64 start = uint64(block.timestamp);
        vm.warp(start + elapsed);

        if (elapsed > inactivity) {
            dms.trigger(subject);
            if (elapsed > uint64(inactivity) + uint64(contest)) {
                // Only reachable at the very top of the bound.
                dms.finalize(subject);
                assertTrue(dms.isReleased(subject));
                return;
            }
        }

        assertFalse(dms.isReleased(subject));
    }

    function _contains(bytes memory haystack, bytes32 needle) private pure returns (bool) {
        if (haystack.length < 32) return false;
        for (uint256 i = 0; i + 32 <= haystack.length; i++) {
            bytes32 window;
            assembly {
                window := mload(add(add(haystack, 0x20), i))
            }
            if (window == needle) return true;
        }
        return false;
    }
}
