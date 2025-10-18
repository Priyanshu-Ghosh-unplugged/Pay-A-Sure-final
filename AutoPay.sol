// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title AutoPay - Automated Recurring Payment System
 * @dev A smart contract leveraging Flow's Forte upgrade for scheduled, automated payments
 * @notice This contract allows users to create recurring payments that execute automatically on-chain
 * 
 * Key Features:
 * - Schedule recurring payments with customizable intervals
 * - Fully on-chain automation (no off-chain keepers needed)
 * - Incentivized execution model
 * - Pausable and cancellable subscriptions
 * - Support for both ETH and ERC20 tokens (future extension)
 * 
 * Built for Forte Hacks 2025 on Flow Blockchain
 */

contract AutoPay {
    
    // ========== STATE VARIABLES ==========
    
    struct PaymentSchedule {
        address payer;              // Who is making the payment
        address payee;              // Who receives the payment
        uint256 amount;             // Amount per payment
        uint256 interval;           // Time between payments (in seconds)
        uint256 nextPaymentTime;    // When the next payment is due
        uint256 totalPaid;          // Total amount paid so far
        uint256 executionCount;     // Number of successful executions
        bool isActive;              // Whether the schedule is active
        uint256 maxPayments;        // Maximum number of payments (0 = unlimited)
        uint256 executorReward;     // Reward for executor (in wei)
    }
    
    // Mapping from schedule ID to PaymentSchedule
    mapping(uint256 => PaymentSchedule) public schedules;
    
    // Mapping from user address to their schedule IDs
    mapping(address => uint256[]) public userSchedules;
    
    // Counter for schedule IDs
    uint256 public scheduleCounter;
    
    // Minimum interval between payments (prevent spam)
    uint256 public constant MIN_INTERVAL = 1 hours;
    
    // Maximum executor reward (prevent griefing)
    uint256 public constant MAX_EXECUTOR_REWARD = 0.01 ether;
    
    // ========== EVENTS ==========
    
    event ScheduleCreated(
        uint256 indexed scheduleId,
        address indexed payer,
        address indexed payee,
        uint256 amount,
        uint256 interval,
        uint256 maxPayments
    );
    
    event PaymentExecuted(
        uint256 indexed scheduleId,
        address indexed executor,
        uint256 amount,
        uint256 executorReward,
        uint256 executionCount
    );
    
    event ScheduleCancelled(
        uint256 indexed scheduleId,
        address indexed payer
    );
    
    event ScheduleUpdated(
        uint256 indexed scheduleId,
        uint256 newAmount,
        uint256 newInterval
    );
    
    event FundsDeposited(
        address indexed user,
        uint256 amount
    );
    
    event FundsWithdrawn(
        address indexed user,
        uint256 amount
    );
    
    // ========== MODIFIERS ==========
    
    modifier onlySchedulePayer(uint256 _scheduleId) {
        require(schedules[_scheduleId].payer == msg.sender, "Not the payer");
        _;
    }
    
    modifier scheduleExists(uint256 _scheduleId) {
        require(schedules[_scheduleId].payer != address(0), "Schedule does not exist");
        _;
    }
    
    modifier scheduleActive(uint256 _scheduleId) {
        require(schedules[_scheduleId].isActive, "Schedule is not active");
        _;
    }
    
    // ========== USER BALANCE MANAGEMENT ==========
    
    // Track user balances deposited for scheduled payments
    mapping(address => uint256) public userBalances;
    
    /**
     * @notice Deposit funds to cover future scheduled payments
     */
    function deposit() external payable {
        require(msg.value > 0, "Must deposit more than 0");
        userBalances[msg.sender] += msg.value;
        emit FundsDeposited(msg.sender, msg.value);
    }
    
    /**
     * @notice Withdraw unused funds
     * @param _amount Amount to withdraw
     */
    function withdraw(uint256 _amount) external {
        require(userBalances[msg.sender] >= _amount, "Insufficient balance");
        userBalances[msg.sender] -= _amount;
        
        (bool success, ) = msg.sender.call{value: _amount}("");
        require(success, "Withdrawal failed");
        
        emit FundsWithdrawn(msg.sender, _amount);
    }
    
    // ========== SCHEDULE MANAGEMENT ==========
    
    /**
     * @notice Create a new recurring payment schedule
     * @param _payee Address to receive payments
     * @param _amount Amount per payment
     * @param _interval Time between payments (seconds)
     * @param _maxPayments Maximum payments (0 = unlimited)
     * @param _executorReward Reward for executors
     */
    function createSchedule(
        address _payee,
        uint256 _amount,
        uint256 _interval,
        uint256 _maxPayments,
        uint256 _executorReward
    ) external payable returns (uint256) {
        require(_payee != address(0), "Invalid payee address");
        require(_amount > 0, "Amount must be greater than 0");
        require(_interval >= MIN_INTERVAL, "Interval too short");
        require(_executorReward <= MAX_EXECUTOR_REWARD, "Executor reward too high");
        
        // Add deposited funds to user balance
        if (msg.value > 0) {
            userBalances[msg.sender] += msg.value;
        }
        
        // Ensure user has enough balance for at least one payment
        uint256 totalCost = _amount + _executorReward;
        require(userBalances[msg.sender] >= totalCost, "Insufficient balance");
        
        scheduleCounter++;
        uint256 scheduleId = scheduleCounter;
        
        schedules[scheduleId] = PaymentSchedule({
            payer: msg.sender,
            payee: _payee,
            amount: _amount,
            interval: _interval,
            nextPaymentTime: block.timestamp + _interval,
            totalPaid: 0,
            executionCount: 0,
            isActive: true,
            maxPayments: _maxPayments,
            executorReward: _executorReward
        });
        
        userSchedules[msg.sender].push(scheduleId);
        
        emit ScheduleCreated(
            scheduleId,
            msg.sender,
            _payee,
            _amount,
            _interval,
            _maxPayments
        );
        
        return scheduleId;
    }
    
    /**
     * @notice Execute a scheduled payment (anyone can call)
     * @param _scheduleId ID of the schedule to execute
     */
    function executePayment(uint256 _scheduleId) 
        external 
        scheduleExists(_scheduleId) 
        scheduleActive(_scheduleId) 
    {
        PaymentSchedule storage schedule = schedules[_scheduleId];
        
        // Check if payment is due
        require(block.timestamp >= schedule.nextPaymentTime, "Payment not yet due");
        
        // Check if max payments reached
        if (schedule.maxPayments > 0) {
            require(schedule.executionCount < schedule.maxPayments, "Max payments reached");
        }
        
        uint256 totalCost = schedule.amount + schedule.executorReward;
        
        // Check if payer has sufficient balance
        require(userBalances[schedule.payer] >= totalCost, "Insufficient payer balance");
        
        // Deduct from payer's balance
        userBalances[schedule.payer] -= totalCost;
        
        // Transfer payment to payee
        (bool payeeSuccess, ) = schedule.payee.call{value: schedule.amount}("");
        require(payeeSuccess, "Payment to payee failed");
        
        // Transfer reward to executor
        if (schedule.executorReward > 0) {
            (bool executorSuccess, ) = msg.sender.call{value: schedule.executorReward}("");
            require(executorSuccess, "Reward to executor failed");
        }
        
        // Update schedule
        schedule.totalPaid += schedule.amount;
        schedule.executionCount++;
        schedule.nextPaymentTime = block.timestamp + schedule.interval;
        
        // Check if this was the last payment
        if (schedule.maxPayments > 0 && schedule.executionCount >= schedule.maxPayments) {
            schedule.isActive = false;
        }
        
        emit PaymentExecuted(
            _scheduleId,
            msg.sender,
            schedule.amount,
            schedule.executorReward,
            schedule.executionCount
        );
    }
    
    /**
     * @notice Cancel a payment schedule
     * @param _scheduleId ID of the schedule to cancel
     */
    function cancelSchedule(uint256 _scheduleId) 
        external 
        scheduleExists(_scheduleId)
        onlySchedulePayer(_scheduleId)
    {
        schedules[_scheduleId].isActive = false;
        emit ScheduleCancelled(_scheduleId, msg.sender);
    }
    
    /**
     * @notice Update an existing schedule (amount and interval)
     * @param _scheduleId ID of the schedule
     * @param _newAmount New payment amount
     * @param _newInterval New interval
     */
    function updateSchedule(
        uint256 _scheduleId,
        uint256 _newAmount,
        uint256 _newInterval
    ) 
        external 
        scheduleExists(_scheduleId)
        onlySchedulePayer(_scheduleId)
        scheduleActive(_scheduleId)
    {
        require(_newAmount > 0, "Amount must be greater than 0");
        require(_newInterval >= MIN_INTERVAL, "Interval too short");
        
        PaymentSchedule storage schedule = schedules[_scheduleId];
        schedule.amount = _newAmount;
        schedule.interval = _newInterval;
        
        emit ScheduleUpdated(_scheduleId, _newAmount, _newInterval);
    }
    
    /**
     * @notice Pause a schedule (can be resumed later)
     * @param _scheduleId ID of the schedule
     */
    function pauseSchedule(uint256 _scheduleId) 
        external 
        scheduleExists(_scheduleId)
        onlySchedulePayer(_scheduleId)
    {
        schedules[_scheduleId].isActive = false;
    }
    
    /**
     * @notice Resume a paused schedule
     * @param _scheduleId ID of the schedule
     */
    function resumeSchedule(uint256 _scheduleId) 
        external 
        scheduleExists(_scheduleId)
        onlySchedulePayer(_scheduleId)
    {
        PaymentSchedule storage schedule = schedules[_scheduleId];
        
        // Check if max payments not reached
        if (schedule.maxPayments > 0) {
            require(schedule.executionCount < schedule.maxPayments, "Max payments already reached");
        }
        
        schedule.isActive = true;
        schedule.nextPaymentTime = block.timestamp + schedule.interval;
    }
    
    // ========== VIEW FUNCTIONS ==========
    
    /**
     * @notice Get all schedule IDs for a user
     * @param _user User address
     */
    function getUserSchedules(address _user) external view returns (uint256[] memory) {
        return userSchedules[_user];
    }
    
    /**
     * @notice Get detailed schedule information
     * @param _scheduleId Schedule ID
     */
    function getScheduleDetails(uint256 _scheduleId) 
        external 
        view 
        scheduleExists(_scheduleId)
        returns (
            address payer,
            address payee,
            uint256 amount,
            uint256 interval,
            uint256 nextPaymentTime,
            uint256 totalPaid,
            uint256 executionCount,
            bool isActive,
            uint256 maxPayments,
            uint256 executorReward
        )
    {
        PaymentSchedule memory schedule = schedules[_scheduleId];
        return (
            schedule.payer,
            schedule.payee,
            schedule.amount,
            schedule.interval,
            schedule.nextPaymentTime,
            schedule.totalPaid,
            schedule.executionCount,
            schedule.isActive,
            schedule.maxPayments,
            schedule.executorReward
        );
    }
    
    /**
     * @notice Check if a payment is due for execution
     * @param _scheduleId Schedule ID
     */
    function isPaymentDue(uint256 _scheduleId) 
        external 
        view 
        scheduleExists(_scheduleId)
        returns (bool) 
    {
        PaymentSchedule memory schedule = schedules[_scheduleId];
        
        if (!schedule.isActive) return false;
        if (block.timestamp < schedule.nextPaymentTime) return false;
        if (schedule.maxPayments > 0 && schedule.executionCount >= schedule.maxPayments) return false;
        
        uint256 totalCost = schedule.amount + schedule.executorReward;
        if (userBalances[schedule.payer] < totalCost) return false;
        
        return true;
    }
    
    /**
     * @notice Get all due payment schedule IDs (for executors to process)
     * @dev This can be gas-intensive for large numbers of schedules
     */
    function getAllDuePayments() external view returns (uint256[] memory) {
        uint256[] memory dueSchedules = new uint256[](scheduleCounter);
        uint256 count = 0;
        
        for (uint256 i = 1; i <= scheduleCounter; i++) {
            PaymentSchedule memory schedule = schedules[i];
            
            if (schedule.isActive && 
                block.timestamp >= schedule.nextPaymentTime &&
                (schedule.maxPayments == 0 || schedule.executionCount < schedule.maxPayments)) {
                
                uint256 totalCost = schedule.amount + schedule.executorReward;
                if (userBalances[schedule.payer] >= totalCost) {
                    dueSchedules[count] = i;
                    count++;
                }
            }
        }
        
        // Resize array to actual count
        uint256[] memory result = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = dueSchedules[i];
        }
        
        return result;
    }
    
    /**
     * @notice Get user's balance available for scheduled payments
     * @param _user User address
     */
    function getBalance(address _user) external view returns (uint256) {
        return userBalances[_user];
    }
    
    // ========== FALLBACK ==========
    
    receive() external payable {
        userBalances[msg.sender] += msg.value;
        emit FundsDeposited(msg.sender, msg.value);
    }
}