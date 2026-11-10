// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Increment — ClearingHouse._settleUserFundingPayments (Trail of Bits, September 2022)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: settleTrader returns a vBase notional (funding rate times the
    position). _settleUserFundingPayments passes that figure to settlePnL with
    no indexPrice conversion. The user is paid 0.05 vBase and 0 UA. The index
    is 20,000 UA per vBase, so the same funding is 1,000 UA.
    The call is ClearingHouse.sol L637-L651. The product is Perpetual._getFundingPayments.
    A 1 vBase short, a 0.05 cumulative funding gap, and index 20,000. */

contract Token {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract Perpetual {
    int256 public userCum;
    int256 public globalCum;
    int256 public position;
    int256 public indexPrice;

    constructor(int256 rate, int256 pos, int256 index) {
        globalCum = rate;
        position = pos;
        indexPrice = index;
    }

    function settleTrader(address) external returns (int256 upcomingFundingPayment) {
        upcomingFundingPayment = _getFundingPayments(false, userCum, globalCum, position);
        userCum = globalCum;
    }

    function _getFundingPayments(
        bool isLong,
        int256 userCumFundingRate,
        int256 globalCumFundingRate,
        int256 vBaseAmountToSettle
    ) internal pure returns (int256 upcomingFundingPayment) {
        if (userCumFundingRate != globalCumFundingRate) {
            int256 upcomingFundingRate = isLong
                ? userCumFundingRate - globalCumFundingRate
                : globalCumFundingRate - userCumFundingRate;
            upcomingFundingPayment = upcomingFundingRate * vBaseAmountToSettle / 1e18;
        }
    }
}

contract Vault {
    Token public vBase;
    Token public ua;
    address public clearingHouse;
    int256 public indexPrice;

    constructor(Token vBase_, Token ua_, int256 index) {
        vBase = vBase_;
        ua = ua_;
        indexPrice = index;
        clearingHouse = msg.sender;
    }

    function setClearingHouse(address next) external {
        require(msg.sender == clearingHouse, "admin");
        clearingHouse = next;
    }

    function settlePnL(address account, int256 fundingPayments) external virtual {
        require(msg.sender == clearingHouse, "ch");
        if (fundingPayments > 0) {
            vBase.mint(account, uint256(fundingPayments));
        }
    }

    function owedUa(int256 fundingPayments) public view returns (int256) {
        return fundingPayments * indexPrice / 1e18;
    }
}

contract VaultFixed is Vault {
    constructor(Token vBase_, Token ua_, int256 index) Vault(vBase_, ua_, index) {}

    function settlePnL(address account, int256 fundingPayments) external override {
        require(msg.sender == clearingHouse, "ch");
        int256 uaAmount = owedUa(fundingPayments);
        if (uaAmount > 0) {
            ua.mint(account, uint256(uaAmount));
        }
    }
}

contract ClearingHouse {
    Perpetual public perpetual;
    Vault public vault;

    constructor(Perpetual perpetual_, Vault vault_) {
        perpetual = perpetual_;
        vault = vault_;
    }

    function settle(address account) external {
        _settleUserFundingPayments(account);
    }

    function _settleUserFundingPayments(address account) internal {
        int256 fundingPayments;
        uint256 numMarkets = 1;
        for (uint256 i = 0; i < numMarkets;) {
            fundingPayments += perpetual.settleTrader(account);
            unchecked {
                ++i;
            }
        }
        if (fundingPayments != 0) {
            // @> VULN: fundingPayments is vBase notional and is not multiplied by indexPrice
            vault.settlePnL(account, fundingPayments);
        }
    }
}

abstract contract FundingScenario {
    address public constant ALICE = 0x00000000000000000000000000000000000000A1;
    int256 public constant POSITION = 1e18;
    int256 public constant RATE = 0.05e18;
    int256 public constant INDEX = 20_000e18;
    uint256 public constant VBASE_PAID = 0.05e18;
    uint256 public constant UA_OWED = 1000e18;

    Token public vBase;
    Token public ua;
    Perpetual public perpetual;
    Vault public vault;
    ClearingHouse public clearing;

    function _wire(bool convert) internal {
        vBase = new Token();
        ua = new Token();
        perpetual = new Perpetual(RATE, POSITION, INDEX);
        if (convert) {
            vault = new VaultFixed(vBase, ua, INDEX);
        } else {
            vault = new Vault(vBase, ua, INDEX);
        }
        clearing = new ClearingHouse(perpetual, vault);
        vault.setClearingHouse(address(clearing));
    }
}

contract Exploit is FundingScenario {
    constructor() {
        _wire(false);
    }

    function run() external {
        clearing.settle(ALICE);
        require(vBase.balanceOf(ALICE) == VBASE_PAID, "token A");
        require(ua.balanceOf(ALICE) == 0, "token B");
        require(uint256(vault.owedUa(int256(VBASE_PAID))) == UA_OWED, "owed");
        require(perpetual.position() == POSITION, "position");
        require(perpetual.indexPrice() == INDEX, "index");
    }
}

contract ControlExploit is FundingScenario {
    constructor() {
        _wire(true);
    }

    function run() external {
        clearing.settle(ALICE);
        require(ua.balanceOf(ALICE) == UA_OWED, "UA");
        require(vBase.balanceOf(ALICE) == 0, "vBase");
    }
}
