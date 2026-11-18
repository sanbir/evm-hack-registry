// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  QuantAMM UpliftOnlyExample — CodeHawks 2024-12.
    onAfterSwap sends the owner fee to address(this). The hook has no
    withdrawal. 1e18 of fee token stays in the hook and the owner balance
    stays 0. The fixed hook sends the same fee to owner().
*/

contract FeeToken {
    string public symbol = "USDC";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Vault {
    FeeToken public token;

    constructor(FeeToken _token) {
        token = _token;
    }

    function sendTo(address feeToken, address to, uint256 amount) external {
        require(feeToken == address(token), "token");
        require(token.transfer(to, amount), "send");
    }
}

contract UpliftOnlyExample {
    Vault internal _vault;
    address public owner;
    event SwapHookFeeCharged(address recipient, address feeToken, uint256 ownerFee);

    constructor(Vault vault_, address owner_) {
        _vault = vault_;
        owner = owner_;
    }

    function onAfterSwap(address feeToken, uint256 ownerFee) external {
        if (ownerFee > 0) {
            // @> VULN: owner fee is sent to this hook, which has no function that can transfer it out
            _vault.sendTo(feeToken, address(this), ownerFee);
            emit SwapHookFeeCharged(address(this), feeToken, ownerFee);
        }
    }
}

contract UpliftOnlyExampleFixed {
    Vault internal _vault;
    address public owner;
    event SwapHookFeeCharged(address recipient, address feeToken, uint256 ownerFee);

    constructor(Vault vault_, address owner_) {
        _vault = vault_;
        owner = owner_;
    }

    function onAfterSwap(address feeToken, uint256 ownerFee) external {
        if (ownerFee > 0) {
            _vault.sendTo(feeToken, owner, ownerFee);
            emit SwapHookFeeCharged(owner, feeToken, ownerFee);
        }
    }
}

contract Exploit {
    uint256 public constant FEE = 1 ether;

    FeeToken public feeToken;
    Vault public vault;
    UpliftOnlyExample public hook;
    address public owner;
    uint256 public hookBalance;
    uint256 public ownerBalance;

    constructor() {
        feeToken = new FeeToken();
        vault = new Vault(feeToken);
        owner = address(0x0A11E5);
        hook = new UpliftOnlyExample(vault, owner);
        feeToken.mint(address(vault), FEE);
    }

    function run() external {
        uint256 quoted = FEE;
        hook.onAfterSwap(address(feeToken), quoted);
        hookBalance = feeToken.balanceOf(address(hook));
        ownerBalance = feeToken.balanceOf(owner);
        require(hookBalance == FEE, "fee locked in hook");
        require(ownerBalance == 0, "owner received nothing");
        require(feeToken.balanceOf(address(vault)) == 0, "vault paid the fee");
        require(hook.owner() == owner, "owner is known");
    }
}
