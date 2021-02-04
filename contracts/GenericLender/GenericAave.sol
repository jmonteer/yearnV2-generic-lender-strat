// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "./GenericLenderBase.sol";
import "../Interfaces/Aave/IAToken.sol";
import "../Interfaces/Aave/ILendingPool.sol";
import "../Libraries/Aave/DataTypes.sol";

/********************
 *   A lender plugin for LenderYieldOptimiser for any erc20 asset on Aave (not eth)
 *   Made by SamPriestley.com
 *   https://github.com/Grandthrax/yearnv2/blob/master/contracts/GenericLender/GenericCream.sol
 *
 ********************* */

contract GenericAave is GenericLenderBase {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    uint256 private constant blocksPerYear = 2_300_000;

    ILendingPool public lendingPool;
    IAToken public aToken;

    constructor(
        address _strategy,
        string memory name,
        ILendingPool _lendingPool,
        IAToken _aToken
    ) public GenericLenderBase(_strategy, name) {
        lendingPool = _lendingPool;
        aToken = _aToken;

        require(_lendingPool.getReserveData(address(want)).aTokenAddress == address(_aToken), "WRONG ATOKEN");

        want.approve(address(_lendingPool), type(uint256).max);
    }

    function nav() external view override returns (uint256) {
        return _nav();
    }

    function _nav() internal view returns (uint256) {
        return want.balanceOf(address(this)).add(underlyingBalanceStored());
    }

    function underlyingBalanceStored() public view returns (uint256 balance) {
        balance = aToken.balanceOf(address(this));
    }

    function apr() external view override returns (uint256) {
        return _apr();
    }

    function _apr() internal view returns (uint256) {
        return lendingPool.getReserveData(address(want)).currentLiquidityRate;
    }

    function weightedApr() external view override returns (uint256) {
        uint256 a = _apr();
        return a.mul(_nav());
    }

    function withdraw(uint256 amount) external override management returns (uint256) {
        return _withdraw(amount);
    }

    //emergency withdraw. sends balance plus amount to governance
    function emergencyWithdraw(uint256 amount) external override management {
        lendingPool.withdraw(address(want), amount, address(this));

        want.safeTransfer(vault.governance(), want.balanceOf(address(this)));
    }

    //withdraw an amount including any want balance
    function _withdraw(uint256 amount) internal returns (uint256) {
        uint256 balanceUnderlying = aToken.balanceOf(address(this));
        uint256 looseBalance = want.balanceOf(address(this));
        uint256 total = balanceUnderlying.add(looseBalance);

        if (amount > total) {
            //cant withdraw more than we own
            amount = total;
        }

        if (looseBalance >= amount) {
            want.safeTransfer(address(strategy), amount);
            return amount;
        }

        //not state changing but OK because of previous call
        uint256 liquidity = want.balanceOf(address(aToken));

        if (liquidity > 1) {
            uint256 toWithdraw = amount.sub(looseBalance);

            if (toWithdraw <= liquidity) {
                //we can take all
                lendingPool.withdraw(address(want), toWithdraw, address(this));
            } else {
                //take all we can
                lendingPool.withdraw(address(want), liquidity, address(this));
            }
        }
        looseBalance = want.balanceOf(address(this));
        want.safeTransfer(address(strategy), looseBalance);
        return looseBalance;
    }

    function deposit() external override management {
        uint256 balance = want.balanceOf(address(this));
        lendingPool.deposit(address(want), balance, address(this), 0);
    }

    function withdrawAll() external override management returns (bool) {
        uint256 invested = _nav();
        uint256 returned = _withdraw(invested);
        return returned >= invested;
    }

    //think about this
    function enabled() external view override returns (bool) {
        return true;
    }

    function hasAssets() external view override returns (bool) {
        return aToken.balanceOf(address(this)) > 0;
    }

    function aprAfterDeposit(uint256 amount) external view override returns (uint256) {
        // uint256 cashPrior = want.balanceOf(address(cToken));

        // uint256 borrows = aToken.totalBorrows();
        // uint256 reserves = aToken.totalReserves();

        // uint256 reserverFactor = cToken.reserveFactorMantissa();
        // InterestRateModel model = cToken.interestRateModel();

        // //the supply rate is derived from the borrow rate, reserve factor and the amount of total borrows.
        // uint256 supplyRate = model.getSupplyRate(cashPrior.add(amount), borrows, reserves, reserverFactor);

        // return supplyRate.mul(blocksPerYear);
    }

    function protectedTokens() internal view override returns (address[] memory) {
        address[] memory protected = new address[](2);
        protected[0] = address(want);
        protected[1] = address(aToken);
        return protected;
    }
}
