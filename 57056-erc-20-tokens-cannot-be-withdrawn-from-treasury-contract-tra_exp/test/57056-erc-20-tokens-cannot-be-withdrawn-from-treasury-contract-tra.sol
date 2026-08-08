// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract FeeToken {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
}

contract Treasury {
    receive() external payable {}
    function withdraw(address target, uint256 value) external {
        require(value <= address(this).balance, "insufficient");
        (bool ok,) = payable(target).call{value: value}("");
        require(ok, "withdraw failed");
    }
}

contract Exploit {
    event Proof(uint256 locked, bool tokenWithdrawalCallSucceeded);
    function run() external {
        Treasury treasury = new Treasury();
        FeeToken token = new FeeToken();
        token.mint(address(treasury), 1000);
        (bool ok,) = address(treasury).call(
            abi.encodeWithSignature("withdrawToken(address,address,uint256)", address(token), msg.sender, 1000)
        );
        emit Proof(token.balanceOf(address(treasury)), ok);
        require(!ok && token.balanceOf(address(treasury)) == 1000, "ERC20 was recoverable");
    }
}
