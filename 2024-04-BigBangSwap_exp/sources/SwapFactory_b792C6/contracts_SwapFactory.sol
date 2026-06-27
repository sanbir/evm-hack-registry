
// SPDX-License-Identifier: MIT

pragma solidity >= 0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import './interfaces/ISwapFactory.sol';
import './interfaces/ISwapPair.sol';
import './SwapPair.sol';

contract SwapFactory is Ownable, ISwapFactory {
    using SafeMath for uint256;

    uint256 public constant FEE_DENOMINATOR = 10000;
    uint256 public override swapFee = 50;  // 0.5%
    address public override feeTo;

    address public override router;

    bytes32 public immutable override initCodeHash;

    //protocol fee percent
    uint256 public override protocolFee = FEE_DENOMINATOR;

    mapping(address => mapping(address => address)) public override getPair;
    address[] public override allPairs;

    event PairCreated(address indexed token0, address indexed token1, address pair, uint _allPairsLength);

    constructor(address feeCollector) Ownable(msg.sender) {

        require(feeCollector != address(0), "invalid feeCollector");

        initCodeHash = keccak256(abi.encodePacked(type(SwapPair).creationCode));

        feeTo = feeCollector;
    }

    function allPairsLength() external view override returns (uint) {
        return allPairs.length;
    }

    function createPair(address tokenA, address tokenB) external override returns (address pair) {
        require(tokenA != tokenB, "SwapFactory: IDENTICAL_ADDRESSES");
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "SwapFactory: ZERO_ADDRESS");
        require(getPair[token0][token1] == address(0), "SwapFactory: PAIR_EXISTS");
        require(msg.sender == router, "SwapFactory: caller must be router");

        // single check is sufficient
        bytes memory bytecode = type(SwapPair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        ISwapPair(pair).initialize(token0, token1);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        // populate mapping in the reverse direction
        allPairs.push(pair);

        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    // fee percent of liquidity provider
    function liquidityFee() external view override returns(uint256){
        return FEE_DENOMINATOR - protocolFee;
    }

    function setFeeTo(address _feeTo) external onlyOwner {
        feeTo = _feeTo;
    }

    // set swap fee, max is 5%
    function setSwapFee(uint256 _swapFee) external onlyOwner {
        require(_swapFee < 500, "SwapFactory: EXCEEDS_DENOMINATOR");
        swapFee = _swapFee;
    }

    // set fee percent of protocol
    function setProtocolFee(uint _protocolFee) external onlyOwner {
        require(_protocolFee <= FEE_DENOMINATOR, "SwapFactory: OVERFLOW");
        protocolFee = _protocolFee;
    }

    function setRouter(address _router) external onlyOwner {
        require(_router != address(0),"router can not be address 0");
        require(ISwapRouter(_router).factory() == address(this),"invalid router");
        router = _router;
    }

    // returns sorted token addresses, used to handle return values from pairs sorted in this order
    function sortTokens(address tokenA, address tokenB) public pure override returns (address token0, address token1) {
        require(tokenA != tokenB, 'SwapFactory: IDENTICAL_ADDRESSES');
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'SwapFactory: ZERO_ADDRESS');
    }

    // calculates the CREATE2 address for a pair without making any external calls
    function pairFor(address tokenA, address tokenB) public view override returns (address pair) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        pair = address(uint160(uint(keccak256(abi.encodePacked(
                hex'ff',
                address(this),
                keccak256(abi.encodePacked(token0, token1)),
                initCodeHash
            )))));
    }
    
    // fetches and sorts the reserves for a pair
    function getReserves(address tokenA, address tokenB) public view override returns (uint reserveA, uint reserveB) {
        (address token0,) = sortTokens(tokenA, tokenB);
        (uint reserve0, uint reserve1,) = ISwapPair(pairFor(tokenA, tokenB)).getReserves();
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    // given some amount of an asset and pair reserves, returns an equivalent amount of the other asset
    function quote(uint amountA, uint reserveA, uint reserveB) public pure override returns (uint amountB) {
        require(amountA > 0, 'SwapFactory: INSUFFICIENT_AMOUNT');
        require(reserveA > 0 && reserveB > 0, 'SwapFactory: INSUFFICIENT_LIQUIDITY');
        amountB = amountA.mul(reserveB) / reserveA;
    }

    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut, address token0, address token1) public view override returns (uint amountOut) {
        require(amountIn > 0, 'SwapFactory: INSUFFICIENT_INPUT_AMOUNT');
        require(reserveIn > 0 && reserveOut > 0, 'SwapFactory: INSUFFICIENT_LIQUIDITY');
        require(token0 != address(0) && token1 != address(0),"invalid tokens");
        uint amountInWithFee = amountIn.mul(FEE_DENOMINATOR.sub(swapFee));
        uint numerator = amountInWithFee.mul(reserveOut);
        uint denominator = reserveIn.mul(FEE_DENOMINATOR).add(amountInWithFee);
        amountOut = numerator / denominator;
    }

    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut, address token0, address token1) public view override returns (uint amountIn) {
        require(amountOut > 0, 'SwapFactory: INSUFFICIENT_OUTPUT_AMOUNT');
        require(reserveIn > 0 && reserveOut > 0, 'SwapFactory: INSUFFICIENT_LIQUIDITY');
        require(token0 != address(0) && token1 != address(0),"invalid tokens");
        uint numerator = reserveIn.mul(amountOut).mul(FEE_DENOMINATOR);
        uint denominator = reserveOut.sub(amountOut).mul(FEE_DENOMINATOR.sub(swapFee));
        amountIn = (numerator / denominator).add(1);
    }
    
    // performs chained getAmountOut calculations on any number of pairs
    function getAmountsOut(uint amountIn, address[] memory path) public view override returns (uint[] memory amounts) {
        require(path.length >= 2, 'MdexSwapFactory: INVALID_PATH');
        amounts = new uint[](path.length);
        amounts[0] = amountIn;
        for (uint i; i < path.length - 1; i++) {
            (uint reserveIn, uint reserveOut) = getReserves(path[i], path[i + 1]);
            amounts[i + 1] = getAmountOut(amounts[i], reserveIn, reserveOut, path[i], path[i + 1]);
        }
    }

    // performs chained getAmountIn calculations on any number of pairs
    function getAmountsIn(uint amountOut, address[] memory path) public view override returns (uint[] memory amounts) {
        require(path.length >= 2, 'MdexSwapFactory: INVALID_PATH');
        amounts = new uint[](path.length);
        amounts[amounts.length - 1] = amountOut;
        for (uint i = path.length - 1; i > 0; i--) {
            (uint reserveIn, uint reserveOut) = getReserves(path[i - 1], path[i]);
            amounts[i - 1] = getAmountIn(amounts[i], reserveIn, reserveOut, path[i - 1], path[i]);
        }
    }
}
