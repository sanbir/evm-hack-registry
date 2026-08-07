pragma solidity >=0.8.0;


interface IOracleTrigger {


   function dispatchToChain(
        uint32 _destinationDomain,
        string memory key
    ) external payable ;

    function getMailBox() external view returns (address);

     function dispatch(
        uint32 _destinationDomain,
        address _recipientAddress,
        string memory _key
    ) external payable;

}

  