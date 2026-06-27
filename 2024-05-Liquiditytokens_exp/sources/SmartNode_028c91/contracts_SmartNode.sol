// contracts/SmartNode.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/access/AccessControl.sol";

abstract contract SmartNodeTreeV1 {
    function totalNodes() external view virtual returns(uint256);
    function nodeRefererOf(address node) external view virtual returns(address);
    function nodeUserReferrerOf(uint256 id) external view virtual returns(address, address);
}

contract SmartNode is AccessControl {
    bytes32 public constant MIGRATOR_ROLE = keccak256("MIGRATOR_ROLE");
    mapping (uint256 => address) private nodeIds;
    mapping (address => uint256) private nodeAddresses;
    mapping (uint256 => uint256) private nodeRefererIds;
    SmartNodeTreeV1 private smartNodeV1;
    uint256 private currentId = 0;
    bool public migrated = false;

    event SmartNodeActivated(address user, address referer, uint256 id);
    event SmartNodeMigrated(address oldNode, address newNode, uint256 id);

    /**
     * @dev Initializes the contract
     */
    constructor(SmartNodeTreeV1 _smartNodeV1) {
        smartNodeV1 = _smartNodeV1;
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(MIGRATOR_ROLE, _msgSender());
    }

    function join(address referer) public {
        require (migrated, "!migrated");
        
        require(nodeAddresses[msg.sender] == 0, "AlreadyJoined!");
        require(nodeAddresses[referer] > 0, "!RefererExists");
        currentId++;
        nodeIds[currentId] = msg.sender;
        nodeAddresses[msg.sender] = currentId;
        nodeRefererIds[currentId] = nodeAddresses[referer];
        emit SmartNodeActivated(msg.sender, referer, currentId);
    }

    function nodeRefererOf(address node) public view returns(address referer) {
        uint256 refererId = nodeRefererIds[nodeAddresses[node]];
        return nodeIds[refererId];
    }

    function nodeUserOf(uint256 id) public view returns(address node) {
        return nodeIds[id];
    }

    function nodeIdOf(address node) public view returns(uint256 id) {
        return nodeAddresses[node];
    }

    function nodeUserReferrerOf(uint256 id) public view returns(address node, address referer) {
        uint256 refererId = nodeRefererIds[id];
        return (nodeIds[id], nodeIds[refererId]);
    }

    function totalNodes() public view returns(uint256 nodeCount) {
        return currentId;
    }

    function isExistingId(uint256 id) public view returns(bool status) {
        return nodeIds[id] != address(0);
    }

    function migrate(uint256 limit) external {
        require (migrated == false, "migrated");
        require (limit > 0, "!limit");
        uint256 i = 1;

        while (i <= limit) {
            _migrate();
            if (migrated) {
                break;
            }
            i++;
        }
    }

    function _migrate() internal  {
        (address account, address referer) = smartNodeV1.nodeUserReferrerOf(currentId + 1);
        if (account == address(0)) {
            migrated = true;
            return;
        }
        currentId++;
        nodeIds[currentId] = account;
        nodeAddresses[account] = currentId;
        nodeRefererIds[currentId] = nodeAddresses[referer];
    }

    function migrateSmartnode(address oldNode, address newNode) external onlyRole(MIGRATOR_ROLE) {
        require (newNode != address(0), "!zeroNewNode");
        uint256 existingNodeId = nodeAddresses[oldNode];
        require (existingNodeId > 0, "!existingOldNode");
        require (nodeAddresses[newNode] == 0, "!existingNewNode");
        nodeIds[existingNodeId] = newNode;
        nodeAddresses[newNode] = existingNodeId;
        nodeAddresses[oldNode] = 0;
        emit SmartNodeMigrated(oldNode, newNode, existingNodeId);
    }

}