// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

// Camp NFT (Quantstamp). Royalty vaults are created only in mint. After the
// NFT is transferred, royaltyVaults(newOwner) is address(0), and the quoted
// payment sends the royalty share there.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transferFrom(address, address, uint256) external returns (bool);
}

contract Erc20 {
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s) {
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract RoyaltyVault {
    address public owner;

    constructor(address _owner) {
        owner = _owner;
    }
}

contract IpNFT {
    mapping(address => address) public royaltyVaults;
    address public holder;

    function mint(address to) external {
        holder = to;
        royaltyVaults[to] = address(new RoyaltyVault(to));
    }

    function transfer(address from, address to) external {
        require(holder == from, "holder");
        holder = to;
    }

    function getOrCreateRoyaltyVault(address tokenOwner) external returns (address vault) {
        vault = royaltyVaults[tokenOwner];
        if (vault == address(0)) {
            vault = address(new RoyaltyVault(tokenOwner));
            royaltyVaults[tokenOwner] = vault;
        }
    }
}

library SafeTransferLib {
    function safeTransferETH(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        require(ok, "ETH_TRANSFER_FAILED");
    }

    function safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FROM_FAILED");
    }
}

contract Marketplace {
    IpNFT public ipToken;
    address public paidTo;
    address public lastRecipient;
    address public lastPaid;
    uint256 public lastShare;

    constructor(IpNFT _ipToken) {
        ipToken = _ipToken;
    }

    /// Quoted payment. `token` is the ERC-20; the vault may be address(0).
    function buyAccess(address token, address payer, address recipient, uint256 share) external {
        address vault = ipToken.royaltyVaults(recipient);
        lastRecipient = recipient;
        lastShare = share;
        if (token == address(0)) {
            SafeTransferLib.safeTransferETH(ipToken.royaltyVaults(recipient), share);
        } else {
            // @> VULN: royaltyVaults(recipient) is address(0), so the share is burned
            this.payShare(token, payer, ipToken.royaltyVaults(recipient), share);
        }
        paidTo = vault;
    }

    /// Quoted SafeTransferLib.safeTransferFrom(token, payer, royaltyVaults(recipient), share).
    function payShare(address token, address from, address to, uint256 amount) external {
        require(msg.sender == address(this), "lib");
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FROM_FAILED");
        lastPaid = to;
    }
}

contract MarketplaceFixed {
    IpNFT public ipToken;

    constructor(IpNFT _ipToken) {
        ipToken = _ipToken;
    }

    function buyAccess(address token, address payer, address recipient, uint256 share) external {
        address vault = ipToken.getOrCreateRoyaltyVault(recipient);
        if (token == address(0)) {
            SafeTransferLib.safeTransferETH(vault, share);
        } else {
            SafeTransferLib.safeTransferFrom(token, payer, vault, share);
        }
    }
}

contract Exploit {
    uint256 internal constant SHARE = 100 ether;
    address internal constant ALICE = address(0x000000000000000000000000000000000000a11c);
    address internal constant BOB = address(0x0000000000000000000000000000000000000B0b);

    Erc20 public pay;
    IpNFT public nft;
    Marketplace public market;

    constructor() {
        pay = new Erc20("PAY");
        nft = new IpNFT();
        market = new Marketplace(nft);
        pay.mint(address(this), SHARE);
    }

    function run() external {
        nft.mint(ALICE);
        nft.transfer(ALICE, BOB);
        require(nft.royaltyVaults(BOB) == address(0), "vault");
        pay.approve(address(market), SHARE);
        market.buyAccess(address(pay), address(this), BOB, SHARE);
        require(pay.balanceOf(address(0)) == SHARE, "burned");
        require(market.paidTo() == address(0), "paid");
        require(nft.royaltyVaults(ALICE) != address(0), "alice");
    }
}
