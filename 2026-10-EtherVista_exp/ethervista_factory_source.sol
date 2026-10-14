pragma solidity =0.5.16;

import './EtherVistaPair.sol';

contract EtherVistaFactory is IEtherVistaFactory {
    address public feeTo;
    address public feeToSetter;
    address public routerSetter; 
    address public router; 

    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    bytes32 public constant INIT_CODE_HASH = keccak256(abi.encodePacked(type(EtherVistaPair).creationCode));

    constructor() public {
        feeToSetter = 0x0000000000000000000000000000000000000000;
        routerSetter = msg.sender;
    }

    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }

    function setRouter(address _router) external {
        require(msg.sender == routerSetter, 'EtherVista: FORBIDDEN');
        router = _router;
    }

    //Can be set to the zero-address if there is no intent to upgrade Router versions
    function setRouterSetter(address setter) external {
        require(msg.sender == routerSetter, 'EtherVista: FORBIDDEN');        
        routerSetter = setter;
    }
    
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, 'EtherVista: IDENTICAL_ADDRESSES');
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'EtherVista: ZERO_ADDRESS');
        require(getPair[token0][token1] == address(0), 'EtherVista: PAIR_EXISTS'); // single check is sufficient
        bytes memory bytecode = type(EtherVistaPair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1)); 
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        IEtherVistaPair(pair).initialize(token0, token1);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, 'EtherVista: FORBIDDEN');
        feeTo = _feeTo;
    }

    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, 'EtherVista: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }
}
