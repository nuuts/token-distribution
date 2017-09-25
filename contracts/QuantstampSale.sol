// Quantstamp Technologies Inc. (info@quantstamp.com)

pragma solidity ^0.4.15;

import './lifecycle/Pausable.sol';
import './math/SafeMath.sol';
import './QuantstampToken.sol';

/**
 * The QuantstampSale smart contract is used for selling QuantstampToken
 * tokens (QSP). It does so by converting ETH received into a quantity of
 * tokens that are transferred to the contributor via the ERC20-compatible
 * transferFrom() function.
 */
contract QuantstampSale is Pausable {

    using SafeMath for uint256;

    // The beneficiary is the future recipient of the funds
    address public beneficiary;

    // The crowdsale has a funding goal, cap, deadline, and minimum contribution
    uint public fundingGoal;
    uint public fundingCap;
    uint public minContribution;
    bool public fundingGoalReached = false;
    bool public fundingCapReached = false;
    bool public saleClosed = false;

    // Time period of sale (UNIX timestamps)
    uint public startTime;
    uint public endTime;

    // Keeps track of the amount of wei raised
    uint public amountRaised;

    // Refund amount, should it be required
    uint public refundAmount;

    // The ratio of QSP to Ether
    uint public rate;
    uint public constant LOW_RANGE_RATE = 5000;
    uint public constant HIGH_RANGE_RATE = 10000;

    // The token being sold
    QuantstampToken public tokenReward;

    // A map that tracks the amount of wei contributed by address
    mapping(address => uint256) public balanceOf;

    // Events
    event GoalReached(address _beneficiary, uint _amountRaised);
    event CapReached(address _beneficiary, uint _amountRaised);
    event FundTransfer(address _backer, uint _amount, bool _isContribution);

    // Modifiers
    modifier beforeDeadline()   { require (currentTime() < endTime); _; }
    modifier afterDeadline()    { require (currentTime() >= endTime); _; }
    modifier saleNotClosed()    { require (!saleClosed); _; }

    modifier validDestination(address _to) {
        require(_to != address(0x0));
        require(_to != address(this));
        require(_to != address(tokenReward.owner()));
        _;
    }

    /**
     * Constructor for a crowdsale of QuantstampToken tokens.
     *
     * @param ifSuccessfulSendTo            the beneficiary of the fund
     * @param fundingGoalInEthers           the minimum goal to be reached
     * @param fundingCapInEthers            the cap (maximum) size of the fund
     * @param minimumContributionInWei      minimum contribution (in wei)
     * @param start                         the start time (UNIX timestamp)
     * @param durationInMinutes             the duration of the crowdsale in minutes
     * @param rateQspToEther                the conversion rate from QSP to Ether
     * @param addressOfTokenUsedAsReward    address of the token being sold
     */
    function QuantstampSale(
        address ifSuccessfulSendTo,
        uint fundingGoalInEthers,
        uint fundingCapInEthers,
        uint minimumContributionInWei,
        uint start,
        uint durationInMinutes,
        uint rateQspToEther,
        address addressOfTokenUsedAsReward
    ) {
        require(ifSuccessfulSendTo != address(0) && ifSuccessfulSendTo != address(this));
        require(addressOfTokenUsedAsReward != address(0) && addressOfTokenUsedAsReward != address(this));
        require(fundingGoalInEthers <= fundingCapInEthers);
        require(durationInMinutes > 0);
        beneficiary = ifSuccessfulSendTo;
        fundingGoal = fundingGoalInEthers * 1 ether;
        fundingCap = fundingCapInEthers * 1 ether;
        minContribution = minimumContributionInWei;
        startTime = start;
        endTime = start + durationInMinutes * 1 minutes; // TODO double check
        setRate(rateQspToEther);
        tokenReward = QuantstampToken(addressOfTokenUsedAsReward);
    }

    /**
     * This fallback function is called whenever Ether is sent to the
     * smart contract. It can only be executed when the crowdsale is
     * not paused, not closed, and before the deadline has been reached.
     *
     * This function will update state variables for whether or not the
     * funding goal or cap have been reached. It also ensures that the
     * tokens are transferred to the sender, and that the correct
     * number of tokens are sent according to the current rate.
     */
    function () payable whenNotPaused beforeDeadline saleNotClosed {
        require(msg.value >= minContribution);

        // Update the sender's balance of wei contributed and the amount raised
        uint amount = msg.value;
        uint currentBalance = balanceOf[msg.sender];
        balanceOf[msg.sender] = currentBalance.add(amount);
        amountRaised = amountRaised.add(amount);

        // Compute the number of tokens to be rewarded to the sender
        // Note: it's important for this calculation that both wei
        // and QSP have the same number of decimal places (18)
        uint numTokens = amount.mul(rate);

        // Transfer the tokens from the crowdsale supply to the sender
        tokenReward.transferFrom(tokenReward.owner(), msg.sender, numTokens);
        FundTransfer(msg.sender, amount, true);

        // Check if the funding goal or cap have been reached
        // TODO check impact on gas cost
        checkFundingGoal();
        checkFundingCap();
    }

    /**
     * The owner can terminate the crowdsale at any time.
     */
    function terminate() external onlyOwner {
        saleClosed = true;
    }

    /**
     * The owner can update the rate (QSP to ETH).
     *
     * @param _rate  the new rate for converting QSP to ETH
     */
    function setRate(uint _rate) public onlyOwner {
        require(_rate >= LOW_RANGE_RATE && _rate <= HIGH_RANGE_RATE);
        rate = _rate;
    }

    /**
     * Set the end time of the crowdsale.
     */
    function setEnd(uint _end) external onlyOwner {
        require(now <= _end);
        endTime = _end;
    }

    /**
     * The owner can allocate the specified amount of tokens from the
     * crowdsale allowance to the recipient (_to).
     *
     * NOTE: be extremely careful to get the amounts correct, which
     * are in units of wei and mini-QSP. Every digit counts.
     *
     * @param to            the recipient of the tokens
     * @param amountWei     the amount contributed in wei
     * @param amountMiniQsp the amount of tokens transferred in mini-QSP
     */
    function ownerAllocateTokens(address to, uint amountWei, uint amountMiniQsp) external onlyOwner validDestination(to) {
        tokenReward.transferFrom(tokenReward.owner(), to, amountMiniQsp);
        uint currentBalance = balanceOf[address(this)];
        balanceOf[address(this)] = currentBalance.add(amountWei);
        amountRaised = amountRaised.add(amountWei);
        FundTransfer(msg.sender, amountWei, true);
    }

    /**
     * The owner can call this function to withdraw the funds that
     * have been sent to this contract for the crowdsale subject to
     * the funding goal having been reached. The funds will be sent
     * to the beneficiary specified when the crowdsale was created.
     */
    function ownerSafeWithdrawal() external onlyOwner {
        require(fundingGoalReached);
        uint balanceToSend = this.balance;
        beneficiary.transfer(balanceToSend);
        FundTransfer(beneficiary, balanceToSend, false);
    }

    /**
     * The owner can unlock the fund with this function. The use-
     * case for this is when the owner decides after the deadline
     * to allow contributors to be refunded their contributions.
     */
    function ownerUnlockFund() external afterDeadline onlyOwner {
        fundingGoalReached = false;
    }

    /**
     * This function permits anybody to withdraw the funds they have
     * contributed if and only if the deadline has passed and the
     * funding goal was not reached.
     */
    function safeWithdrawal() external afterDeadline {
        if (!fundingGoalReached) {
            uint amount = balanceOf[msg.sender];
            balanceOf[msg.sender] = 0;
            if (amount > 0) {
                msg.sender.transfer(amount);
                FundTransfer(msg.sender, amount, false);
                refundAmount = refundAmount.add(amount);
            }
        }
    }

    /**
     * Checks if the funding goal has been reached. If it has, then
     * the GoalReached event is triggered.
     */
    function checkFundingGoal() internal {
        if (!fundingGoalReached) {
            if (amountRaised >= fundingGoal) {
                fundingGoalReached = true;
                GoalReached(beneficiary, amountRaised);
            }
        }
    }

    /**
     * Checks if the funding cap has been reached. If it has, then
     * the CapReached event is triggered.
     */
    function checkFundingCap() internal {
        if (!fundingCapReached) {
            if (amountRaised >= fundingCap) {
                fundingCapReached = true;
                saleClosed = true;
                CapReached(beneficiary, amountRaised);
            }
        }
    }

    /**
     * Returns the current time.
     * Useful to abstract calls to "now" for tests.
    */
    function currentTime() returns (uint _currentTime) {
        return now;
    }


    /**
     * Given an amount in QSP, this method returns the equivalent amount
     * in mini-QSP.
     *
     * @param amount    an amount expressed in units of QSP
     */
    function convertToMiniQsp(uint amount) internal constant returns (uint) {
        return amount * (10 ** uint(tokenReward.decimals()));
    }
}
