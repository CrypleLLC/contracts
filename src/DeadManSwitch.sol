// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract DeadManSwitch {
    enum Status {
        Unconfigured,
        Active,
        Contest,
        Released
    }

    struct Record {
        uint64 lastCheckIn;
        uint32 inactivityPeriod;
        uint32 contestPeriod;
        bytes32 guardianRoot;
        uint8 guardianThreshold;
        Status status;
        uint64 triggeredAt;
    }

    uint32 public immutable minInactivityPeriod;
    uint32 public immutable minContestPeriod;

    mapping(address owner => Record) private _records;

    event Configured(
        address indexed owner,
        uint32 inactivityPeriod,
        uint32 contestPeriod,
        bytes32 guardianRoot,
        uint8 guardianThreshold
    );
    event CheckedIn(address indexed owner, uint64 at);
    event Triggered(address indexed owner, uint64 at, uint64 releasableAt);
    event Revoked(address indexed owner, uint64 at);
    event Released(address indexed owner, uint64 at);

    error PeriodTooShort(uint32 given, uint32 minimum);
    error InvalidGuardianConfig();
    error AlreadyReleased();
    error NotConfigured();
    error NotActive();
    error NotContesting();
    error DeadlineNotReached(uint64 nowTs, uint64 deadline);

    constructor(uint32 minInactivity, uint32 minContest) {
        minInactivityPeriod = minInactivity;
        minContestPeriod = minContest;
    }

    function recordOf(address owner) external view returns (Record memory) {
        return _records[owner];
    }

    function statusOf(address owner) external view returns (Status) {
        return _records[owner].status;
    }

    function isReleased(address owner) external view returns (bool) {
        return _records[owner].status == Status.Released;
    }

    // The deadline after which trigger() may be called. Zero when not applicable.
    function triggerableAt(address owner) public view returns (uint64) {
        Record storage record = _records[owner];
        if (record.status != Status.Active) return 0;
        return record.lastCheckIn + record.inactivityPeriod;
    }

    // The deadline after which finalize() may be called. Zero when not applicable.
    function releasableAt(address owner) public view returns (uint64) {
        Record storage record = _records[owner];
        if (record.status != Status.Contest) return 0;
        return record.triggeredAt + record.contestPeriod;
    }

    // Owner-only. The caller is the account itself: nothing server-side may ever
    // configure or check in on a user's behalf.
    function configure(uint32 inactivityPeriod, uint32 contestPeriod, bytes32 guardianRoot, uint8 guardianThreshold)
        external
    {
        if (inactivityPeriod < minInactivityPeriod) revert PeriodTooShort(inactivityPeriod, minInactivityPeriod);
        if (contestPeriod < minContestPeriod) revert PeriodTooShort(contestPeriod, minContestPeriod);
        if (guardianRoot == bytes32(0)) {
            if (guardianThreshold != 0) revert InvalidGuardianConfig();
        } else if (guardianThreshold == 0) {
            revert InvalidGuardianConfig();
        }

        Record storage record = _records[msg.sender];
        if (record.status == Status.Released) revert AlreadyReleased();

        bool wasContesting = record.status == Status.Contest;

        record.inactivityPeriod = inactivityPeriod;
        record.contestPeriod = contestPeriod;
        record.guardianRoot = guardianRoot;
        record.guardianThreshold = guardianThreshold;
        record.lastCheckIn = uint64(block.timestamp);
        record.status = Status.Active;
        record.triggeredAt = 0;

        if (wasContesting) emit Revoked(msg.sender, uint64(block.timestamp));

        emit Configured(msg.sender, inactivityPeriod, contestPeriod, guardianRoot, guardianThreshold);
        emit CheckedIn(msg.sender, uint64(block.timestamp));
    }

    // Owner-only. During Contest this revokes the pending release, as configure() also does.
    function checkIn() external {
        Record storage record = _records[msg.sender];

        if (record.status == Status.Released) revert AlreadyReleased();
        if (record.status == Status.Unconfigured) revert NotConfigured();

        record.lastCheckIn = uint64(block.timestamp);

        if (record.status == Status.Contest) {
            record.status = Status.Active;
            record.triggeredAt = 0;
            emit Revoked(msg.sender, uint64(block.timestamp));
        }

        emit CheckedIn(msg.sender, uint64(block.timestamp));
    }

    // Permissionless: if only one party could advance a record, that party's
    // disappearance would freeze every switch.
    function trigger(address owner) external {
        Record storage record = _records[owner];
        if (record.status != Status.Active) revert NotActive();

        uint64 deadline = record.lastCheckIn + record.inactivityPeriod;
        if (block.timestamp <= deadline) revert DeadlineNotReached(uint64(block.timestamp), deadline);

        record.status = Status.Contest;
        record.triggeredAt = uint64(block.timestamp);

        emit Triggered(owner, uint64(block.timestamp), uint64(block.timestamp) + record.contestPeriod);
    }

    // Permissionless. Released is terminal by design.
    function finalize(address owner) external {
        Record storage record = _records[owner];
        if (record.status != Status.Contest) revert NotContesting();

        uint64 deadline = record.triggeredAt + record.contestPeriod;
        if (block.timestamp <= deadline) revert DeadlineNotReached(uint64(block.timestamp), deadline);

        record.status = Status.Released;

        emit Released(owner, uint64(block.timestamp));
    }
}
