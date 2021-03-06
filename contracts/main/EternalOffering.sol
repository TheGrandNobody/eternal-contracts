//SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "../interfaces/ILoyaltyGage.sol";
import "../gages/LoyaltyGage.sol";
import "@traderjoe-xyz/core/contracts/traderjoe/interfaces/IJoeRouter02.sol";
import "@traderjoe-xyz/core/contracts/traderjoe/interfaces/IJoeFactory.sol";
import "@traderjoe-xyz/core/contracts/traderjoe/interfaces/IJoePair.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Contract for the Eternal gaging platform
 * @author Nobody (me)
 * @notice The Eternal contract holds all user-data and gage logic.
 */
contract EternalOffering {

/////–––««« Variables: Events, Interfaces and Addresses »»»––––\\\\\

    // Signals the deployment of a new gage
    event NewGage(uint256 id, address indexed gageAddress);

    // The Joe router interface
    IJoeRouter02 public immutable joeRouter;
    // The Joe factory interface
    IJoeFactory public immutable joeFactory;
    // The Eternal token interface
    IERC20 public immutable eternal;
    // The Eternal storage interface
    IEternalStorage public immutable eternalStorage;
    // The Eternal treasury interface
    IEternalTreasury public immutable eternalTreasury;

    // The address of the ETRNL-USDCe pair
    address public immutable usdcePair;
    // The address of the ETRNL-AVAX pair
    address public immutable avaxPair;

/////–––««« Variables: Mappings »»»––––\\\\\

    // Keeps track of the respective gage tied to any given ID
    mapping (uint256 => address) private gages;
    // Keeps track of whether a user is in a loyalty gage or has provided liquidity for this offering
    mapping (address => mapping (address => bool)) private participated;
    // Keeps track of the amount of ETRNL the user has used in liquidity provision
    mapping (address => uint256) private liquidityOffered;
    // Keeps track of the amount of ETRNL the user has deposited
    mapping (address => uint256) private liquidityDeposited;

/////–––««« Variables: Constants, immutables and factors »»»––––\\\\\

    // The timestamp at which this contract will cease to offer
    uint256 private offeringEnds;
    // The holding time constant used in the percent change condition calculation (decided by the Eternal Fund) (x 10 ** 6)
    uint256 public constant TIME_FACTOR = 6 * (10 ** 6);
    // The average amount of time that users provide liquidity for
    uint256 public constant TIME_CONSTANT = 15;
    // The minimum token value estimate of transactions in 24h
    uint256 public constant ALPHA = 10 ** 7 * (10 ** 18);
    // The number of ETRNL allocated
    uint256 public constant LIMIT = 4207500 * (10 ** 21);
    // The USDCe address
    address public constant USDCe = 0xA7D7079b0FEaD91F3e65f86E8915Cb59c1a4C664;

/////–––««« Variables: Gage/Liquidity bookkeeping »»»––––\\\\\

    // Keeps track of the latest Gage ID
    uint256 private lastId;
    // The total amount of ETRNL needed for current active gages
    uint256 private totalETRNLForGages;
    // The total number of ETRNL dispensed in this offering thus far
    uint256 private totalETRNLOffered;
    // The total number of USDCe-ETRNL lp tokens acquired
    uint256 private totalLpUSDCe;
    // The total number of AVAX-ETRNL lp tokens acquired
    uint256 private totalLpAVAX;

    // Allows contract to receive AVAX tokens
    // solhint-disable-next-line no-empty-blocks
    receive() external payable {}

/////–––««« Constructor »»»––––\\\\\

    constructor (address _storage, address _eternal, address _treasury) {
        // Set the initial Eternal storage and token interfaces
        IEternalStorage _eternalStorage = IEternalStorage(_storage);
        eternalStorage = _eternalStorage;
        eternal = IERC20(_eternal);

        // Initialize the Trader Joe router and factory
        IJoeRouter02 _joeRouter = IJoeRouter02(0x60aE616a2155Ee3d9A68541Ba4544862310933d4);
        IJoeFactory _joeFactory = IJoeFactory(_joeRouter.factory());
        joeRouter = _joeRouter;
        joeFactory = _joeFactory;

        // Create the pairs
        address _avaxPair = _joeFactory.createPair(_eternal, _joeRouter.WAVAX());
        address _usdcePair = _joeFactory.createPair(_eternal, USDCe);
        avaxPair = _avaxPair;
        usdcePair = _usdcePair;
        
        eternalTreasury = IEternalTreasury(_treasury);
    }

    function initialize() external {
        // Exclude the pairs from rewards
        bytes32 avaxExcluded = keccak256(abi.encodePacked("isExcludedFromRewards", avaxPair));
        bytes32 usdceExcluded = keccak256(abi.encodePacked("isExcludedFromRewards", usdcePair));
        bytes32 token = keccak256((abi.encodePacked(address(eternal))));
        bytes32 excludedAddresses = keccak256(abi.encodePacked("excludedAddresses"));
        if (!eternalStorage.getBool(token, avaxExcluded)) {
            eternalStorage.setBool(token, avaxExcluded, true);
            eternalStorage.setBool(token, usdceExcluded, true);
            eternalStorage.setAddressArrayValue(excludedAddresses, 0, avaxPair);
            eternalStorage.setAddressArrayValue(excludedAddresses, 0, usdcePair);
            offeringEnds = block.timestamp + 1 days;
        }
    }

/////–––««« Variable state-inspection functions »»»––––\\\\\

    /**
     * @notice Computes the equivalent of an asset to an other asset and the minimum amount of the two needed to provide liquidity.
     * @param asset The first specified asset, which we want to convert 
     * @param otherAsset The other specified asset
     * @param amountAsset The amount of the first specified asset
     * @param uncertainty The minimum loss to deduct from each minimum in case of price changes
     * @return minOtherAsset The minimum amount of otherAsset needed to provide liquidity (not given if uncertainty = 0)
     * @return minAsset The minimum amount of Asset needed to provide liquidity (not given if uncertainty = 0)
     * @return amountOtherAsset The equivalent in otherAsset of the given amount of asset
     */
    function _computeMinAmounts(address asset, address otherAsset, uint256 amountAsset, uint256 uncertainty) private view returns (uint256 minOtherAsset, uint256 minAsset, uint256 amountOtherAsset) {
        // Get the reserve ratios for the Asset-otherAsset pair
        (uint256 reserveA, uint256 reserveB,) = IJoePair(joeFactory.getPair(asset, otherAsset)).getReserves();
        (uint256 reserveAsset, uint256 reserveOtherAsset) = asset < otherAsset ? (reserveA, reserveB) : (reserveB, reserveA);

        // Determine a reasonable minimum amount of asset and otherAsset based on current reserves (with a tolerance =  1 / uncertainty)
        amountOtherAsset = joeRouter.quote(amountAsset, reserveAsset, reserveOtherAsset);
        if (uncertainty != 0) {
            minAsset = joeRouter.quote(amountOtherAsset, reserveOtherAsset, reserveAsset);
            minAsset -= minAsset / uncertainty;
            minOtherAsset = amountOtherAsset - (amountOtherAsset / uncertainty);
        }
    }

    /**
     * @notice View the total ETRNL offered in this IGO.
     * @return uint256 The total ETRNL distributed in this offering
     */
    function viewTotalETRNLOffered() external view returns (uint256) {
        return totalETRNLOffered;
    }

    /**
     * @notice View the total number of USDCe-ETRNL and AVAX-ETRNL lp tokens earned in this IGO.
     * @return uint256 The total number of lp tokens for the USDCe-ETRNl pair in this contract
     * @return uint256 The total number of lp tokens for the AVAX-ETRNL pair in this contract
     */
    function viewTotalLp() external view returns (uint256, uint256) {
        return (totalLpUSDCe, totalLpAVAX);
    }

    /**
     * @notice View the amount of ETRNL a given user has been offered in total.
     * @param user The specified user
     * @return uint256 The total amount of ETRNL offered for the user
     */
    function viewLiquidityOffered(address user) external view returns (uint256) {
        return liquidityOffered[user];
    }

    /**
     * @notice View the amount of ETRNL a given user has deposited (through provideLiquidity)
     * @param user The specified user
     * @return uint256 The total amount of ETRNL that has been deposited (but not gaged)
     */
    function viewLiquidityDeposited(address user) external view returns (uint256) {
        return liquidityDeposited[user];
    }

    /**
     * @notice View the address of a given loyalty gage.
     * @param id The id of the specified gage
     * @return address The address of the loyalty gage for this id
     */
    function viewGage(uint256 id) external view returns (address) {
        return gages[id];
    }

    /**
     * @notice View the current risk percentage for loyalty gages.
     * @return risk The percentage which the treasury takes if the loyalty gage closes in its favor
     */
    function viewRisk() public view returns (uint256 risk) {
        risk = totalETRNLOffered < LIMIT / 4 ? 3100 : (totalETRNLOffered < LIMIT / 2 ? 2600 : (totalETRNLOffered < LIMIT * 3 / 4 ? 2100 : 1600));
    }

    /**
     * @notice Evaluate whether the individual limit is reached for a given user and amount of ETRNL.
     * @return bool Whether transacting this amount of ETRNL respects the IGO limit for this user
     */
    function checkIndividualLimit(uint256 amountETRNL, address user) public view returns (bool) {
        return amountETRNL + liquidityOffered[user] <= (10 ** 7) * (10 ** 18);
    }

    /**
     * @notice Evaluate whether the global IGO limit is reached for a given amount of ETRNL
     * @return bool Whether there is enough ETRNL left to allow this IGO transaction
     */
    function checkGlobalLimit(uint256 amountETRNL) public view returns (bool) {
        return totalETRNLOffered + 2 * amountETRNL <= LIMIT;
    }
    
/////–––««« Gage-logic functions »»»––––\\\\\

    /**
     * @notice Provides liquidity to a given ETRNL/Asset pair
     * @param asset The asset in the ETRNL/Asset pair
     * @param amountETRNL The amount of ETRNL to add if we provide liquidity to the ETRNL/AVAX pair
     * @param minETRNL The min amount of ETRNL to be used in this operation
     * @param minAsset The min amount of the Asset to be used in this operation
     */
    function _provide(address asset, uint256 amount, uint256 amountETRNL, uint256 minETRNL, uint256 minAsset) private returns (uint256 providedETRNL, uint256 providedAsset) {
        uint256 liquidity;
        if (asset == joeRouter.WAVAX()) {
            (providedETRNL, providedAsset, liquidity) = joeRouter.addLiquidityAVAX{value: msg.value}(address(eternal), amountETRNL, minETRNL, minAsset, address(this), block.timestamp);
            totalLpAVAX += liquidity;
        } else {
            require(IERC20(asset).approve(address(joeRouter), amountETRNL), "Approve failed");
            (providedETRNL, providedAsset, liquidity) = joeRouter.addLiquidity(address(eternal), asset, amountETRNL, amount, minETRNL, minAsset, address(this), block.timestamp);
            totalLpUSDCe += liquidity;
        }
    }

    /**
     * @notice Creates an ETRNL loyalty gage contract for a given user and amount.
     * @param amount The amount of the asset being deposited in the loyalty gage by the receiver
     * @param asset The address of the asset being deposited in the loyalty gage by the receiver
     *
     * Requirements:
     * 
     * - The offering must be ongoing
     * - Only USDCe or AVAX loyalty gages are offered
     * - There can not have been more than 4 250 000 000 ETRNL offered in total
     * - A user can only participate in a maximum of one loyalty gage per asset
     * - A user can not send money to gages/provide liquidity for more than 10 000 000 ETRNL 
     * - The sum of the new amount provided and the previous amounts provided by a user can not exceed the equivalent of 10 000 000 ETRNL
     */
    function initiateEternalLoyaltyGage(uint256 amount, address asset) external payable {
        // Checks
        require(block.timestamp < offeringEnds, "Offering is over");
        require(asset == USDCe || (asset == joeRouter.WAVAX() && msg.value == amount), "Only USDCe or AVAX");
        require(!participated[msg.sender][asset], "User gage limit reached");

        // Compute the minimum amounts needed to provide liquidity and the equivalent of the asset in ETRNL
        (uint256 minETRNL, uint256 minAsset, uint256 amountETRNL) = _computeMinAmounts(asset, address(eternal), amount, 100);
        // Calculate risk
        uint256 rRisk = viewRisk();
        require(checkIndividualLimit(amountETRNL + (2 * amountETRNL * (rRisk - 100) / (10 ** 4)), msg.sender), "Amount exceeds the user limit");
        require(checkGlobalLimit(amountETRNL + (amountETRNL * (rRisk - 100) / (10 ** 4))), "ETRNL offering limit is reached");

        // Compute the percent change condition
        uint256 percent = 500 * ALPHA * TIME_CONSTANT * TIME_FACTOR / eternal.totalSupply();

        // Incremement the lastId tracker and increase the total ETRNL count
        lastId += 1;
        participated[msg.sender][asset] = true;

        // Deploy a new Gage
        LoyaltyGage newGage = new LoyaltyGage(lastId, percent, 2, false, address(this), msg.sender, address(eternalStorage));
        emit NewGage(lastId, address(newGage));
        gages[lastId] = address(newGage);

        //Transfer the deposit
        if (msg.value == 0) {
            require(IERC20(asset).transferFrom(msg.sender, address(this), amount), "Failed to deposit asset");
        }

        // Add liquidity to the ETRNL/Asset pair
        require(eternal.approve(address(joeRouter), amountETRNL), "Approve failed");
        (uint256 providedETRNL, uint256 providedAsset) = _provide(asset, amount, amountETRNL, minETRNL, minAsset);
        // Calculate the difference in asset given vs asset provided
        providedETRNL += (amount - providedAsset) * providedETRNL / amount;

        // Update the offering variables
        liquidityOffered[msg.sender] += providedETRNL + (2 * providedETRNL * (rRisk - 100) / (10 ** 4));
        totalETRNLOffered += 2 * (providedETRNL + (providedETRNL * (rRisk - 100) / (10 ** 4)));
        totalETRNLForGages += providedETRNL + (providedETRNL * (rRisk - 100) / (10 ** 4));

        // Initialize the loyalty gage and transfer the user's instant reward
        newGage.initialize(asset, address(eternal), amount, providedETRNL, rRisk, rRisk - 100);
        require(eternal.transfer(msg.sender, providedETRNL * (rRisk - 100) / (10 ** 4)), "Failed to transfer bonus");
    }

    /**
     * @notice Settles a given loyalty gage closed by a given receiver.
     * @param receiver The specified receiver 
     * @param id The specified id of the gage
     * @param winner Whether the gage closed in favour of the receiver
     *
     * Requirements:
     * 
     * - Only callable by a loyalty gage
     */
    function settleGage(address receiver, uint256 id, bool winner) external {
        // Checks
        address _gage = gages[id];
        require(msg.sender == _gage, "msg.sender must be the gage");

        // Load all gage data
        ILoyaltyGage gage = ILoyaltyGage(_gage);
        (,, uint256 rRisk) = gage.viewUserData(receiver);
        (,uint256 dAmount, uint256 dRisk) = gage.viewUserData(address(this));

        // Compute and transfer the net gage deposit due to the receiver
        if (winner) {
            dAmount += dAmount * dRisk / (10 ** 4);
        } else {
            dAmount -= dAmount * rRisk / (10 ** 4);
        }
        totalETRNLForGages -= dAmount * rRisk / (10 ** 4);
        require(eternal.transfer(receiver, dAmount), "Failed to transfer ETRNL");
    }

/////–––««« Liquidity Provision functions »»»––––\\\\\

    /**
     * @notice Provides liquidity to either the USDCe-ETRNL or AVAX-ETRNL pairs and sends ETRNL the msg.sender.
     * @param amount The amount of the asset being provided
     * @param asset The address of the asset being provided
     *
     * Requirements:
     * 
     * - The offering must be ongoing
     * - Only USDCe or AVAX can be used in providing liquidity
     * - There can not have been more than 4 250 000 000 ETRNL offered in total
     * - A user can not send money to gages/provide liquidity for more than 10 000 000 ETRNL 
     * - The sum of the new amount provided and the previous amounts provided by a user can not exceed the equivalent of 10 000 000 ETRNL
     */
    function provideLiquidity(uint256 amount, address asset) external payable {
        // Checks
        require(block.timestamp < offeringEnds, "Offering is over");
        require(asset == USDCe || asset == joeRouter.WAVAX(), "Only USDCe or AVAX");

        // Compute the minimum amounts needed to provide liquidity and the equivalent of the asset in ETRNL
        (uint256 minETRNL, uint256 minAsset, uint256 amountETRNL) = _computeMinAmounts(asset, address(eternal), amount, 200);
        require(checkIndividualLimit(amountETRNL, msg.sender), "Amount exceeds the user limit");
        require(checkGlobalLimit(amountETRNL), "ETRNL offering limit is reached");

        // Transfer user's funds to this contract if it's not already done
        if (msg.value == 0) {
            require(IERC20(asset).transferFrom(msg.sender, address(this), amount), "Failed to deposit funds");
        }

        // Add liquidity to the ETRNL/Asset pair
        require(eternal.approve(address(joeRouter), amountETRNL), "Approve failed");
        (uint256 providedETRNL, uint256 providedAsset) = _provide(asset, amount, amountETRNL, minETRNL, minAsset);

        // Update the offering variables
        totalETRNLOffered += providedETRNL;
        // Calculate and add the difference in asset given vs asset provided
        providedETRNL += (amount - providedAsset) * providedETRNL / amount;
        // Update the offering variables
        liquidityOffered[msg.sender] += providedETRNL;
        liquidityDeposited[msg.sender] += providedETRNL;
        totalETRNLOffered += providedETRNL;

        // Transfer ETRNL to the user
        require(eternal.transfer(msg.sender, providedETRNL), "ETRNL transfer failed");
    }

/////–––««« Post-Offering functions »»»––––\\\\\

    /**
     * @notice Transfers all lp tokens, leftover ETRNL and any dust present in this contract to the Eternal Treasury.
     * 
     * Requirements:
     *
     * - Either the time limit or ETRNL limit must be met
     */
    function sendLPToTreasury() external {
        // Checks
        require(totalETRNLOffered == LIMIT || offeringEnds < block.timestamp, "Offering not over yet");
        bytes32 treasury = keccak256(abi.encodePacked(address(eternalTreasury)));
        uint256 usdceBal = IERC20(USDCe).balanceOf(address(this));
        uint256 etrnlBal = eternal.balanceOf(address(this));
        uint256 avaxBal = address(this).balance;
        // Send the USDCe and AVAX balance of this contract to the Eternal Treasury if there is any dust leftover
        if (usdceBal > 0) {
            require(IERC20(USDCe).transfer(address(eternalTreasury), usdceBal), "USDCe Transfer failed");
        }
        if (avaxBal > 0) {
            (bool success,) = payable(address(eternalTreasury)).call{value: avaxBal}("");
            require(success, "AVAX transfer failed");
        }

        // Send any leftover ETRNL from this offering to the Eternal Treasury
        if (etrnlBal > totalETRNLForGages) {
            uint256 leftoverETRNL = etrnlBal - totalETRNLForGages;
            eternalTreasury.updateReserves(address(eternalTreasury), leftoverETRNL, eternalTreasury.convertToReserve(leftoverETRNL), true);
            require(eternal.transfer(address(eternalTreasury), leftoverETRNL), "ETRNL transfer failed");
        }

        // Send the lp tokens earned from this offering to the Eternal Treasury
        bytes32 usdceLiquidity = keccak256(abi.encodePacked("liquidityProvided", address(eternalTreasury), USDCe));
        bytes32 avaxLiquidity = keccak256(abi.encodePacked("liquidityProvided", address(eternalTreasury), joeRouter.WAVAX()));
        eternalStorage.setUint(treasury, usdceLiquidity, totalLpUSDCe);
        eternalStorage.setUint(treasury, avaxLiquidity, totalLpAVAX);
        require(IERC20(avaxPair).transfer(address(eternalTreasury), totalLpAVAX), "Failed to transfer AVAX lp");
        require(IERC20(usdcePair).transfer(address(eternalTreasury), totalLpUSDCe), "Failed to transfer USDCe lp");
    }
}