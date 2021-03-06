//SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title FundLock contract
 * @author Nobody (me)
 * @notice The FundLock contract holds funds for a given time period. This is particularly useful for automated token vesting. 
 */
contract FundLock {

    // The Eternal Token interface
    IERC20 public immutable eternal;

    // The address of the recipient
    address public immutable recipient;

    // The maximum supply of the token
    uint256 public immutable maxSupply;
    // The total amount of tokens being vested (multiplied by 10 ** 18 for decimal-precision)
    uint256 public immutable totalAmount;
    // The factor by which to release a given number of vested tokens
    uint256 public immutable gamma;

    constructor (address _eternal, address _recipient, uint256 _totalAmount, uint256 _maxSupply, uint256 _gamma) {
        eternal = IERC20(_eternal);
        recipient = _recipient;
        totalAmount = _totalAmount * (10 ** 18);
        maxSupply = _maxSupply;
        gamma = _gamma;
    }

    /**
     * @notice View the amount of tokens available for withdrawal based on the amount the supply has decreased by
     * @return uint256 The maximum amount of tokens available to be withdrawn by investors from this contract at this time
     */
    function viewAmountAvailable() public view returns (uint256) {
        uint256 deltaSupply = maxSupply - eternal.totalSupply();
        uint256 amountAvailable = totalAmount * deltaSupply * gamma / maxSupply;
        return amountAvailable > totalAmount ? totalAmount : amountAvailable;
    }

    /**
     * @notice Withraws (part of) locked funds proportional to the deflation of the circulation supply of the token
     */
    function withdrawFunds() external {
        uint256 amountWithdrawn = totalAmount - eternal.balanceOf(address(this));
        require(eternal.transfer(recipient, viewAmountAvailable() - amountWithdrawn), "Failed to withdraw funds");
    }
}