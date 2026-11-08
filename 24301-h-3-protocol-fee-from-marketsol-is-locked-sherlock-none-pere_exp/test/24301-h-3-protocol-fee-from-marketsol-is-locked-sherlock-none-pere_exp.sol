// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    Token18,
    Market,
    UFixed18,
    IMarket
} from "./24301-h-3-protocol-fee-from-marketsol-is-locked-sherlock-none-pere.sol";

interface IInstanceFixed {}

/// Same claim path, plus the withdraw the audited factory does not have.
contract MarketFactoryFixed {
    error FactoryNotInstanceError();

    Token18 public token;
    address public immutable oracleFactory;
    mapping(address => bool) private _instances;

    constructor(address token_, address oracleFactory_) {
        token = Token18(token_);
        oracleFactory = oracleFactory_;
    }

    function instances(IInstanceFixed instance) public view returns (bool) {
        return _instances[address(instance)];
    }

    function register(address market) external {
        _instances[market] = true;
    }

    function fund(IMarket market) external {
        if (!instances(IInstanceFixed(address(market)))) revert FactoryNotInstanceError();
        market.claimFee();
    }

    function withdraw(address treasury) external {
        uint256 bal = token.balanceOf(address(this));
        token.push(treasury, UFixed18.wrap(bal));
    }
}

contract Finding24301Test is Test {
    function test_exploit_protocol_fee_locks_in_the_factory() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.token().balanceOf(address(e.factory())), e.FEE(), "250 TOK locked in the factory");
        assertEq(e.token().balanceOf(e.TREASURY()), 0, "treasury received nothing");
        assertEq(e.token().balanceOf(address(e.market())), 0, "market no longer holds the fee");
        assertEq(e.market().protocolFee(), 0, "accrued fee was cleared");
        assertEq(e.FEE(), 250e18, "fee amount");
    }

    function test_control_withdraw_pays_the_treasury() public {
        Token18 token = new Token18();
        Market market = new Market(address(token));
        MarketFactoryFixed factory = new MarketFactoryFixed(address(token), address(0x2222));
        address treasury = address(0xBEEF);
        market.bind(address(factory), address(0x3333), address(0x4444), 250e18);
        factory.register(address(market));
        token.mint(address(market), 250e18);

        factory.fund(market);
        assertEq(token.balanceOf(address(factory)), 250e18, "claim still lands on the factory");
        assertEq(token.balanceOf(treasury), 0, "treasury not paid yet");

        factory.withdraw(treasury);
        assertEq(token.balanceOf(treasury), 250e18, "treasury received the protocol fee");
        assertEq(token.balanceOf(address(factory)), 0, "factory did not keep the fee");
        assertEq(market.protocolFee(), 0, "accrued fee was cleared");
    }
}
