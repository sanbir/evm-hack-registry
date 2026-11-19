// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Zaros LiquidationBranch.liquidateAccounts (Cyfrin, 2024-07).
    The account has 900 collateral and +300 unrealized PnL. Maintenance is
    1100. The quoted path deducts collateral without minting the positive PnL,
    so the liquidator receives 900 and the 300 is discarded. The account is
    left at 0. The fixed path mints the 300 first, pays 1100, and leaves 100.
*/

contract USDZ {
    string public symbol = "USDZ";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract Engine {
    USDZ public usdz;
    uint256 public requiredMaintenance;
    mapping(address => uint256) public collateral;
    mapping(address => int256) public unrealizedPnl;
    uint256 public lastTake;

    constructor(USDZ _usdz) {
        usdz = _usdz;
    }

    function seed(address user, uint256 col, int256 pnl, uint256 required) external {
        collateral[user] = col;
        unrealizedPnl[user] = pnl;
        requiredMaintenance = required;
    }

    // Quoted liquidateAccounts body: maintenance is deducted from collateral
    // and the positive unrealized PnL is never minted onto the account.
    function liquidate(address user) external {
        int256 pnl = unrealizedPnl[user];
        uint256 col = collateral[user];
        uint256 margin = col;
        require(requiredMaintenance > margin && pnl > 0, "healthy");
        uint256 take = col;
        collateral[user] = col - take;
        unrealizedPnl[user] = 0;
        lastTake = take;
        usdz.transfer(msg.sender, take); // @> VULN: pays the 900 collateral; the +300 PnL was never minted
    }
}

contract EngineFixed {
    USDZ public usdz;
    uint256 public requiredMaintenance;
    mapping(address => uint256) public collateral;
    mapping(address => int256) public unrealizedPnl;

    constructor(USDZ _usdz) {
        usdz = _usdz;
    }

    function seed(address user, uint256 col, int256 pnl, uint256 required) external {
        collateral[user] = col;
        unrealizedPnl[user] = pnl;
        requiredMaintenance = required;
    }

    function liquidate(address user) external {
        int256 pnl = unrealizedPnl[user];
        if (pnl > 0) {
            usdz.mint(address(this), uint256(pnl));
            collateral[user] += uint256(pnl);
            unrealizedPnl[user] = 0;
        }
        uint256 col = collateral[user];
        require(col >= requiredMaintenance, "short");
        uint256 take = requiredMaintenance;
        collateral[user] = col - take;
        usdz.transfer(msg.sender, take);
    }
}

contract LostMarker {
    string public symbol = "LOST-PNL";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }
}

contract Exploit {
    uint256 public constant COL = 900 ether;
    uint256 public constant PNL = 300 ether;
    uint256 public constant REQUIRED = 1100 ether;
    address public constant USER = 0x2222222222222222222222222222222222222222;
    address public constant SINK = 0x000000000000000000000000000000000000D00d;

    USDZ public usdz;
    Engine public engine;
    LostMarker public marker;

    function run() external {
        usdz = new USDZ();
        engine = new Engine(usdz);
        marker = new LostMarker();
        usdz.mint(address(engine), COL);
        engine.seed(USER, COL, int256(PNL), REQUIRED);
        engine.liquidate(USER);
        require(engine.collateral(USER) == 0, "collateral wiped");
        require(engine.unrealizedPnl(USER) == 0, "pnl cleared");
        require(usdz.balanceOf(address(this)) == COL, "liquidator got only the collateral");
        require(engine.lastTake() == COL, "take");
        marker.mint(SINK, PNL);
        require(marker.balanceOf(SINK) == PNL, "300 pnl lost");
    }
}
