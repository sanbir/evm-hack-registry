// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  LEND — _handleLiquidationSuccess passes destEid 0 (Sherlock H-25)
    SYNTHETIC, cheatcode-free reduction.
    The stored collateral row has destEid 2. findCrossChainCollateral
    requires every field to match, including destEid. The success handler
    passes 0, so the lookup misses, require(found) reverts, and the
    liquidator's escrowed 500 stays in the router. A second call fails
    the same way. The control passes destEid 2 and pays the 500 out. */

contract Usd {
    string public constant symbol = "USD";
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

contract LendStorage {
    struct Borrow {
        uint256 srcEid;
        uint256 destEid;
        uint256 principle;
        address borrowedlToken;
        address srcToken;
    }

    mapping(address => mapping(address => Borrow[])) internal collaterals;
    mapping(address => address) public lTokenToUnderlying;

    function setUnderlying(address lToken, address underlying) external {
        lTokenToUnderlying[lToken] = underlying;
    }

    function add(address user, address underlying, Borrow memory row) external {
        collaterals[user][underlying].push(row);
    }

    function findCrossChainCollateral(
        address user,
        address underlying,
        uint256 srcEid,
        uint256 destEid,
        address borrowedlToken,
        address srcToken
    ) public view returns (bool, uint256) {
        Borrow[] memory rows = collaterals[user][underlying];
        for (uint256 i = 0; i < rows.length;) {
            if (
                rows[i].srcEid == srcEid && rows[i].destEid == destEid && rows[i].borrowedlToken == borrowedlToken
                    && rows[i].srcToken == srcToken
            ) {
                return (true, i);
            }
            unchecked {
                ++i;
            }
        }
        return (false, 0);
    }
}

contract CrossChainRouter {
    LendStorage public lendStorage;
    Usd public usd;
    uint32 public currentEid;

    struct Payload {
        uint256 amount;
        address sender;
        address destlToken;
        address liquidator;
        address srcToken;
    }

    constructor(LendStorage store, Usd token, uint32 eid) {
        lendStorage = store;
        usd = token;
        currentEid = eid;
    }

    function escrow(uint256 amount) external {
        usd.mint(address(this), amount);
    }

    function handleLiquidationSuccess(Payload memory payload) external {
        address underlying = lendStorage.lTokenToUnderlying(payload.destlToken);
        // @> VULN: destEid is hardcoded to 0, so the stored collateral row is never found
        (bool found, uint256 index) = lendStorage.findCrossChainCollateral(
            payload.sender, underlying, currentEid, 0, payload.destlToken, payload.srcToken
        );
        index;
        require(found, "Borrow position not found");
        usd.transfer(payload.liquidator, payload.amount);
    }

    function handleLiquidationSuccessFixed(Payload memory payload, uint256 destEid) external {
        address underlying = lendStorage.lTokenToUnderlying(payload.destlToken);
        (bool found, uint256 index) = lendStorage.findCrossChainCollateral(
            payload.sender, underlying, currentEid, destEid, payload.destlToken, payload.srcToken
        );
        index;
        require(found, "Borrow position not found");
        usd.transfer(payload.liquidator, payload.amount);
    }
}

contract Exploit {
    Usd public usd;
    LendStorage public store;
    CrossChainRouter public router;
    uint256 public constant ESCROW = 500e18;
    uint32 public constant SRC_EID = 101;
    uint256 public constant DEST_EID = 2;

    constructor() {
        usd = new Usd();
        store = new LendStorage();
        router = new CrossChainRouter(store, usd, SRC_EID);
    }

    function run() external {
        address borrower = address(0xB0B0);
        address lToken = address(0x1701);
        address underlying = address(0xA55E7);
        store.setUnderlying(lToken, underlying);
        store.add(
            borrower,
            underlying,
            LendStorage.Borrow({
                srcEid: SRC_EID,
                destEid: DEST_EID,
                principle: ESCROW,
                borrowedlToken: lToken,
                srcToken: underlying
            })
        );
        router.escrow(ESCROW);
        CrossChainRouter.Payload memory payload = CrossChainRouter.Payload({
            amount: ESCROW,
            sender: borrower,
            destlToken: lToken,
            liquidator: msg.sender,
            srcToken: underlying
        });
        (bool first,) = address(router).call(
            abi.encodeCall(CrossChainRouter.handleLiquidationSuccess, (payload))
        );
        (bool second,) = address(router).call(
            abi.encodeCall(CrossChainRouter.handleLiquidationSuccess, (payload))
        );
        uint256 stuck = usd.balanceOf(address(router));
        uint256 liquidatorBefore = usd.balanceOf(msg.sender);
        router.escrow(ESCROW);
        router.handleLiquidationSuccessFixed(payload, DEST_EID);
        uint256 paid = usd.balanceOf(msg.sender) - liquidatorBefore;
        require(first == false, "first liquidation reverts");
        require(second == false, "second liquidation reverts");
        require(stuck == ESCROW, "500 stuck");
        require(liquidatorBefore == 0, "liquidator unpaid");
        require(paid == ESCROW, "control pays 500");
        require(stuck - liquidatorBefore == ESCROW, "stuck by 500");
    }
}
