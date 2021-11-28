//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @dev Eternal interface
 * @author Nobody (me)
 * @notice Methods are used for all gage-related functioning
 */
interface IEternal {
    // Initiates a standard gage
    function initiateStandardGage(uint32 users) external returns(uint256);
    // Deposit an asset to the platform
    function deposit(address asset, address user, uint256 amount, uint256 id) external;
    // Withdraw an asset from the platform
    function withdraw(address user, uint256 id) external;
    // Set the fee rate of the platform
    function setFeeRate(uint16 newRate) external;
    
    event NewGage(uint256 id, address indexed gageAddress);
    event FeeRateChanged(uint16 oldRate, uint16 newRate);
}