// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Boba L1ERC1155Bridge — finalizeWithdrawalBatch encodes finalizeDeposit
    instead of finalizeDepositBatch when replyNeeded (Quantstamp / Pavel
    Shabarkin, finding #60699).

    SYNTHETIC, cheatcode-free. The batch (ids 1 and 2, 400 + 600) is escrowed
    as N = 1000. The reply uses the single-deposit selector, so the L2 call
    reverts on payload length and the escrow is not returned. Control encodes
    finalizeDepositBatch and the user gets N back. */

contract Token {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        require(allowance[from][msg.sender] >= amount, "allow");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

interface IL2ERC1155Bridge {
    function finalizeDeposit(address user, uint256 id, uint256 amount) external;
    function finalizeDepositBatch(address user, uint256[] calldata ids, uint256[] calldata amounts) external;
}

contract L1ERC1155Bridge {
    Token public token;
    address public l2;

    constructor(Token _token) {
        token = _token;
    }

    function setL2(address _l2) external {
        require(l2 == address(0), "l2");
        l2 = _l2;
    }

    function refund(address user, uint256 amount) external {
        require(msg.sender == l2, "l2");
        token.transfer(user, amount);
    }

    function finalizeWithdrawalBatch(
        address user,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bool replyNeeded
    ) external {
        require(ids.length == amounts.length && ids.length > 1, "batch");
        uint256 sum;
        for (uint256 i; i < amounts.length; i++) sum += amounts[i];
        token.transferFrom(user, address(this), sum);
        if (replyNeeded) {
            // @> VULN: batch reply uses the single-deposit selector
            bytes memory message =
                abi.encodeWithSelector(IL2ERC1155Bridge.finalizeDeposit.selector, user, ids, amounts);
            (bool ok,) = l2.call(message);
            ok;
        }
    }
}

contract L2ERC1155Bridge {
    address public l1;

    constructor(address _l1) {
        l1 = _l1;
    }

    function finalizeDeposit(address, uint256, uint256) external pure {
        // A batch payload is longer than address + two words, so it does not fit.
        require(msg.data.length == 4 + 32 * 3, "shape");
    }

    function finalizeDepositBatch(address user, uint256[] calldata, uint256[] calldata amounts) external {
        uint256 sum;
        for (uint256 i; i < amounts.length; i++) sum += amounts[i];
        L1ERC1155Bridge(l1).refund(user, sum);
    }
}

contract Exploit {
    uint256 public constant N = 1000 ether;

    Token public token;
    L2ERC1155Bridge public l2;
    L1ERC1155Bridge public l1;
    uint256 public stuck;
    uint256 public left;

    constructor() {
        token = new Token("Bridged 1155", "B1155", 18);
        l1 = new L1ERC1155Bridge(token);
        l2 = new L2ERC1155Bridge(address(l1));
        l1.setL2(address(l2));
    }

    function run() external {
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        amounts[0] = 400 ether;
        amounts[1] = 600 ether;
        token.mint(address(this), N);
        token.approve(address(l1), N);
        l1.finalizeWithdrawalBatch(address(this), ids, amounts, true);
        stuck = token.balanceOf(address(l1));
        left = token.balanceOf(address(this));
        require(stuck == N, "batch was refunded");
        require(left == 0, "user kept the batch");
    }
}

/// @dev Control bridge: the reply uses finalizeDepositBatch.
contract L1BridgeFixed {
    Token public token;
    address public l2;

    constructor(Token _token) {
        token = _token;
    }

    function setL2(address _l2) external {
        require(l2 == address(0), "l2");
        l2 = _l2;
    }

    function refund(address user, uint256 amount) external {
        require(msg.sender == l2, "l2");
        token.transfer(user, amount);
    }

    function finalizeWithdrawalBatch(
        address user,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bool replyNeeded
    ) external {
        uint256 sum;
        for (uint256 i; i < amounts.length; i++) sum += amounts[i];
        token.transferFrom(user, address(this), sum);
        if (replyNeeded) {
            bytes memory message =
                abi.encodeWithSelector(IL2ERC1155Bridge.finalizeDepositBatch.selector, user, ids, amounts);
            (bool ok,) = l2.call(message);
            require(ok, "reply");
        }
    }
}
