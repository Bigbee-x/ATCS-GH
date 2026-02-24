#!/usr/bin/env python3
"""
ATCS-GH Phase 2 | Deep Q-Network Agent
════════════════════════════════════════
DQN implementation for adaptive traffic signal control.

Architecture:
  DQNetwork   — feed-forward MLP approximating Q(state, action)
  ReplayBuffer — circular experience replay buffer
  DQNAgent     — full DQN agent (double DQN, target network, ε-greedy)

The agent observes a 17-dimensional state vector from the SUMO simulation
and outputs one of two actions: keep current green phase, or switch.

Phase 2 → Phase 3 extension points are marked with # [EXTEND].
"""

import random
import numpy as np
from collections import deque
from pathlib import Path

import torch
import torch.nn as nn
import torch.optim as optim


# ── Neural Network ────────────────────────────────────────────────────────────

class DQNetwork(nn.Module):
    """
    Multi-layer perceptron Q-network: maps state → Q-value per action.

    Architecture: input → [hidden layers with ReLU] → output
    Xavier initialisation for stable early training.

    # [EXTEND] Replace with a dueling DQN architecture for Phase 3:
    #   separate value stream V(s) and advantage stream A(s,a)
    """

    def __init__(self,
                 state_size:    int,
                 action_size:   int,
                 hidden_sizes:  list[int] = (128, 128)):
        super().__init__()

        layers: list[nn.Module] = []
        in_size = state_size
        for h in hidden_sizes:
            layers += [nn.Linear(in_size, h), nn.ReLU()]
            in_size = h
        layers.append(nn.Linear(in_size, action_size))

        self.net = nn.Sequential(*layers)

        # Xavier init: ensures variance is consistent through the network
        for m in self.modules():
            if isinstance(m, nn.Linear):
                nn.init.xavier_uniform_(m.weight)
                nn.init.zeros_(m.bias)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.net(x)


# ── Replay Buffer ─────────────────────────────────────────────────────────────

class ReplayBuffer:
    """
    Fixed-capacity circular buffer of (s, a, r, s', done) transitions.

    Random sampling breaks the temporal correlations in sequential
    experience, which is critical for stable DQN training.
    """

    def __init__(self, capacity: int = 100_000):
        self.buffer: deque = deque(maxlen=capacity)

    def push(self,
             state:      np.ndarray,
             action:     int,
             reward:     float,
             next_state: np.ndarray,
             done:       bool) -> None:
        self.buffer.append((
            np.asarray(state,      dtype=np.float32),
            int(action),
            float(reward),
            np.asarray(next_state, dtype=np.float32),
            bool(done),
        ))

    def sample(self, batch_size: int) -> tuple:
        """Return a random mini-batch as five numpy arrays."""
        batch = random.sample(self.buffer, batch_size)
        states, actions, rewards, next_states, dones = zip(*batch)
        return (
            np.array(states,      dtype=np.float32),
            np.array(actions,     dtype=np.int64),
            np.array(rewards,     dtype=np.float32),
            np.array(next_states, dtype=np.float32),
            np.array(dones,       dtype=np.float32),
        )

    def __len__(self) -> int:
        return len(self.buffer)


# ── DQN Agent ─────────────────────────────────────────────────────────────────

class DQNAgent:
    """
    Double DQN agent with experience replay and a target network.

    Key design choices:
      • Double DQN: policy_net selects action, target_net evaluates it.
        Prevents overestimation of Q-values.
      • Hard target update every TARGET_UPDATE_FREQ steps.
      • Huber (SmoothL1) loss: less sensitive to outlier rewards than MSE.
      • Gradient clipping at 10.0: prevents exploding gradients.
      • Apple Silicon MPS support: uses Metal GPU if available.

    Typical training loop:
        agent = DQNAgent()
        for episode in range(N_EPISODES):
            state = env.reset()
            done  = False
            while not done:
                action                          = agent.select_action(state)
                next_state, reward, done, info  = env.step(action)
                agent.remember(state, action, reward, next_state, done)
                agent.learn()
                state = next_state
            agent.decay_epsilon()

    # [EXTEND] For Phase 3 multi-intersection:
    #   Use one agent per junction or a shared agent with junction_id in state.
    """

    # ── Hyperparameters ───────────────────────────────────────────────────────
    GAMMA              = 0.95      # Discount factor (future vs immediate reward)
    LEARNING_RATE      = 1e-3      # Adam optimiser learning rate
    BATCH_SIZE         = 64        # Mini-batch size for each gradient update
    BUFFER_SIZE        = 100_000   # Replay buffer capacity (≈14 episodes of experience)
    TARGET_UPDATE_FREQ = 200       # Hard target network sync interval (steps)
    MIN_BUFFER_SIZE    = 1_000     # Steps to collect before learning starts
    EPSILON_START      = 1.0       # Full exploration at episode 1
    EPSILON_MIN        = 0.05      # Minimum exploration (5% random actions)
    EPSILON_DECAY      = 0.92      # Multiplicative decay applied after each episode
    #   After episode: 10 → ε≈0.43  |  20 → ε≈0.19  |  30 → ε≈0.08  |  37 → ε=0.05

    def __init__(self,
                 state_size:  int = 17,
                 action_size: int = 2,
                 device:      str | None = None):

        self.state_size  = state_size
        self.action_size = action_size

        # Device selection: prefer MPS (Apple Silicon) → CUDA → CPU
        if device:
            self.device = torch.device(device)
        elif torch.backends.mps.is_available():
            self.device = torch.device("mps")
        elif torch.cuda.is_available():
            self.device = torch.device("cuda")
        else:
            self.device = torch.device("cpu")

        # Policy network: trained every step
        self.policy_net = DQNetwork(state_size, action_size).to(self.device)

        # Target network: frozen copy updated every TARGET_UPDATE_FREQ steps
        self.target_net = DQNetwork(state_size, action_size).to(self.device)
        self.target_net.load_state_dict(self.policy_net.state_dict())
        self.target_net.eval()  # Never call .backward() on target_net

        self.optimiser  = optim.Adam(self.policy_net.parameters(),
                                     lr=self.LEARNING_RATE)
        self.memory     = ReplayBuffer(self.BUFFER_SIZE)
        self.epsilon    = self.EPSILON_START
        self.step_count = 0     # Global step counter (used for target net sync)

        print(f"[DQN] Initialised on {self.device}")
        print(f"      Architecture: {state_size} → 128 → 128 → {action_size}")
        print(f"      Parameters  : {sum(p.numel() for p in self.policy_net.parameters()):,}")

    # ── Action Selection ──────────────────────────────────────────────────────

    def select_action(self, state: np.ndarray) -> int:
        """
        ε-greedy action selection.

        Training:   explore randomly with probability ε (decays over episodes)
        Evaluation: always exploit (call set_eval_mode() first to set ε=0)
        """
        if random.random() < self.epsilon:
            return random.randint(0, self.action_size - 1)

        with torch.no_grad():
            t = torch.FloatTensor(state).unsqueeze(0).to(self.device)
            q = self.policy_net(t)
        return int(q.argmax(dim=1).item())

    # ── Learning ──────────────────────────────────────────────────────────────

    def remember(self,
                 state:      np.ndarray,
                 action:     int,
                 reward:     float,
                 next_state: np.ndarray,
                 done:       bool) -> None:
        """Store one transition in the replay buffer."""
        self.memory.push(state, action, reward, next_state, done)

    def learn(self) -> float | None:
        """
        Sample a mini-batch and perform one gradient update on policy_net.

        Uses Double DQN Bellman equation:
            a*       = argmax_a' Q_policy(s', a')            (policy selects)
            target Q = r  +  γ · Q_target(s', a*)            (target evaluates)
                     = r                                      if done

        Returns:
            Scalar loss value, or None if buffer is not yet large enough.
        """
        if len(self.memory) < self.MIN_BUFFER_SIZE:
            return None

        states, actions, rewards, next_states, dones = \
            self.memory.sample(self.BATCH_SIZE)

        states      = torch.FloatTensor(states).to(self.device)
        actions     = torch.LongTensor(actions).to(self.device)
        rewards     = torch.FloatTensor(rewards).to(self.device)
        next_states = torch.FloatTensor(next_states).to(self.device)
        dones       = torch.FloatTensor(dones).to(self.device)

        # Q(s, a) for the actions that were actually taken
        q_curr = self.policy_net(states).gather(1, actions.unsqueeze(1)).squeeze(1)

        # Double DQN: policy_net selects best action, target_net evaluates it.
        # This decouples selection from evaluation, reducing Q-value overestimation.
        with torch.no_grad():
            best_actions = self.policy_net(next_states).argmax(1)
            q_next       = self.target_net(next_states).gather(
                               1, best_actions.unsqueeze(1)
                           ).squeeze(1)
            q_target     = rewards + self.GAMMA * q_next * (1.0 - dones)

        # Huber loss: quadratic for small errors, linear for large (robust)
        loss = nn.SmoothL1Loss()(q_curr, q_target)

        self.optimiser.zero_grad()
        loss.backward()
        nn.utils.clip_grad_norm_(self.policy_net.parameters(), max_norm=10.0)
        self.optimiser.step()

        self.step_count += 1
        if self.step_count % self.TARGET_UPDATE_FREQ == 0:
            self._sync_target()

        return float(loss.item())

    def decay_epsilon(self) -> None:
        """Apply one episode's worth of ε-decay. Call once per episode end."""
        self.epsilon = max(self.EPSILON_MIN, self.epsilon * self.EPSILON_DECAY)

    def _sync_target(self) -> None:
        """Hard copy: policy_net weights → target_net weights."""
        self.target_net.load_state_dict(self.policy_net.state_dict())

    # ── Persistence ───────────────────────────────────────────────────────────

    def save(self, path: str | Path) -> None:
        """Save the full agent state (weights + optimiser + metadata)."""
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        torch.save({
            "policy_net":  self.policy_net.state_dict(),
            "target_net":  self.target_net.state_dict(),
            "optimiser":   self.optimiser.state_dict(),
            "epsilon":     self.epsilon,
            "step_count":  self.step_count,
            "state_size":  self.state_size,
            "action_size": self.action_size,
        }, path)

    def load(self, path: str | Path) -> None:
        """
        Load a checkpoint. Safe to call before or after construction.
        Restores weights, optimiser state, and epsilon for seamless resumption.
        """
        checkpoint = torch.load(path, map_location=self.device,
                                weights_only=False)
        self.policy_net.load_state_dict(checkpoint["policy_net"])
        self.target_net.load_state_dict(checkpoint["target_net"])
        self.optimiser.load_state_dict(checkpoint["optimiser"])
        self.epsilon    = checkpoint.get("epsilon",    self.EPSILON_MIN)
        self.step_count = checkpoint.get("step_count", 0)
        self._sync_target()
        print(f"[DQN] Loaded: {path}  (ε={self.epsilon:.3f}, "
              f"steps={self.step_count:,})")

    def set_eval_mode(self) -> None:
        """
        Switch to pure exploitation mode for inference / evaluation.
        Sets ε=0 and disables dropout/batchnorm (no effect here but good practice).
        """
        self.epsilon = 0.0
        self.policy_net.eval()
