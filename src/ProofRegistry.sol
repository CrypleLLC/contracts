// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract ProofRegistry {
    uint64 public constant EPOCH_SECONDS = 86400;

    mapping(address account => mapping(uint64 epoch => bytes32 root)) private _roots;
    mapping(address account => uint64 epoch) private _latestEpoch;

    event Anchored(address indexed account, uint64 indexed epoch, bytes32 root);

    error EmptyRoot();
    error EpochInTheFuture(uint64 epoch, uint64 currentEpoch);
    error EpochAlreadyAnchored(uint64 epoch, bytes32 existingRoot);

    // Owner-signed only. A relayer authorised to anchor could anchor the root of
    // tampered data, and the heir's verification would then pass against it.
    function anchor(uint64 epoch, bytes32 root) external {
        if (root == bytes32(0)) revert EmptyRoot();

        uint64 current = currentEpoch();
        if (epoch > current) revert EpochInTheFuture(epoch, current);

        if (epoch < current) {
            bytes32 existing = _roots[msg.sender][epoch];
            if (existing != bytes32(0)) revert EpochAlreadyAnchored(epoch, existing);
        }

        _roots[msg.sender][epoch] = root;
        if (epoch > _latestEpoch[msg.sender]) {
            _latestEpoch[msg.sender] = epoch;
        }

        emit Anchored(msg.sender, epoch, root);
    }

    function rootAt(address account, uint64 epoch) external view returns (bytes32) {
        return _roots[account][epoch];
    }

    function latestEpoch(address account) external view returns (uint64) {
        return _latestEpoch[account];
    }

    function latestRoot(address account) external view returns (uint64 epoch, bytes32 root) {
        epoch = _latestEpoch[account];
        return (epoch, _roots[account][epoch]);
    }

    function currentEpoch() public view returns (uint64) {
        return uint64(block.timestamp) / EPOCH_SECONDS;
    }
}
