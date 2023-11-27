using PDDL, SymbolicPlanners
using Gen, GenParticleFilters
using InversePlanning
using PDDLViz, GLMakie, Printf

include("utils.jl")

#--- Initial Setup ---#

# Register PDDL array theory
PDDL.Arrays.register!()

# Load domain and problem
domain = load_domain(joinpath(@__DIR__, "domain.pddl"))
problem = load_problem(joinpath(@__DIR__, "problems", "problem-6.pddl"))

# Initialize state and construct goal specification
state = initstate(domain, problem)
spec = Specification(problem)

# Compile domain for faster performance
domain, state = PDDL.compiled(domain, state)

#--- Define Renderer ---#

# Construct gridworld renderer
gem_colors = PDDLViz.colorschemes[:vibrant]
renderer = PDDLViz.GridworldRenderer(
    resolution = (600, 700),
    agent_renderer = (d, s) -> HumanGraphic(color=:black),
    obj_renderers = Dict(
        :key => (d, s, o) -> KeyGraphic(
            visible=!s[Compound(:has, [o])]
        ),
        :door => (d, s, o) -> LockedDoorGraphic(
            visible=s[Compound(:locked, [o])]
        ),
        :gem => (d, s, o) -> GemGraphic(
            visible=!s[Compound(:has, [o])],
            color=gem_colors[parse(Int, string(o.name)[end])]
        )
    ),
    show_inventory = true,
    inventory_fns = [(d, s, o) -> s[Compound(:has, [o])]],
    inventory_types = [:item]
)

# Visualize initial state
canvas = renderer(domain, state)

#--- Visualize Plans ---#

# Check that A* heuristic search correctly solves the problem
planner = AStarPlanner(GoalManhattan(), save_search=true)
sol = planner(domain, state, spec)

# Visualize resulting plan
plan = collect(sol)
canvas = renderer(canvas, domain, state, plan)
@assert satisfy(domain, sol.trajectory[end], problem.goal) == true

# Visualise search tree
canvas = renderer(canvas, domain, state, sol, show_trajectory=false)

# Animate plan
anim = anim_plan(renderer, domain, state, plan;
                 format="gif", framerate=5, trail_length=10)

#--- Model Configuration ---#

# Specify possible goals
goals = @pddl("(has gem1)", "(has gem2)", "(has gem3)")
goal_idxs = collect(1:length(goals))
goal_names = ["red", "yellow", "blue"]
goal_colors = gem_colors[goal_idxs]

# Define uniform prior over possible goals
@gen function goal_prior()
    goal ~ uniform_discrete(1, length(goals))
    return Specification(goals[goal])
end

# Construct iterator over goal choicemaps for stratified sampling
goal_addr = :init => :agent => :goal => :goal
goal_strata = choiceproduct((goal_addr, 1:length(goals)))

# Configure agent model with domain, planner, and goal prior
heuristic = RelaxedMazeDist()
planner = ProbAStarPlanner(heuristic, search_noise=0.1, save_search=true)
agent_config = AgentConfig(
    domain, planner;
    # Assume fixed goal over time
    goal_config = StaticGoalConfig(goal_prior),
    # Assume the agent randomly replans over time
    replan_args = (
        prob_replan = 0.1, # Probability of replanning at each timestep
        budget_dist = shifted_neg_binom, # Search budget distribution
        budget_dist_args = (2, 0.05, 1) # Budget distribution parameters
    ),
    # Assume a small amount of action noise
    act_epsilon = 0.05,
)

# Define observation noise model
obs_params = ObsNoiseParams(
    (pddl"(xpos)", normal, 1.0),
    (pddl"(ypos)", normal, 1.0),
    (pddl"(forall (?d - door) (locked ?d))", 0.05),
    (pddl"(forall (?i - item) (has ?i))", 0.05),
    (pddl"(forall (?i - item) (offgrid ?i))", 0.05)
)
obs_params = ground_obs_params(obs_params, domain, state)
obs_terms = collect(keys(obs_params))

# Configure world model with planner, goal prior, initial state, and obs params
world_config = WorldConfig(
    agent_config = agent_config,
    env_config = PDDLEnvConfig(domain, state),
    obs_config = MarkovObsConfig(domain, obs_params)
)

#--- Model Visualization ---#

# Construct trace renderer
trace_renderer = TraceRenderer(
    renderer;
    show_past = true, show_future = true, show_sol = true, show_title = true,
    n_past = 20, n_future = 50,
    past_options = Dict(
        :agent_color => :black,
        :agent_start_color => (:black, 0.0),
        :track_markersize => 0.4
    ),
    future_options = Dict(
        :agent_color => (trace, t, weight) -> begin
            goal_idx = trace[goal_addr]
            return PDDLViz.set_alpha(goal_colors[goal_idx], 0.75)
        end,
        :track_markersize => 0.5
    ),
    sol_options = Dict(
        :show_trajectory => false
    ),
    title_fn = (trace, t, weight) -> begin
        goal_idx = trace[goal_addr]
        return "t = $t, goal = $(goal_names[goal_idx])"
    end
)

# Sample trace from world model with fixed goal
world_trace, _ = generate(world_model, (50, world_config),
                          choicemap((goal_addr, 3)))

# Visualize trace (press left/right arrow keys to step through time)
canvas = trace_renderer(domain, world_trace, 10; interactive=true)

# Animate trace
anim = anim_trace(trace_renderer, domain, world_trace;
                  format="gif", framerate=5)

# Sample and render multiple traces
world_traces = [simulate(world_model, (30, world_config)) for _ in 1:9];
trace_renderer.show_sol = false
figure = trace_renderer(domain, world_traces; interactive = true,
                        figure_options = (resolution=(960, 1200),))

#--- Test Trajectory Generation ---#

# Construct a trajectory with backtracking to perform inference on
sol1 = planner(domain, state, pddl"(has key2)")
sol2 = planner(domain, sol1.trajectory[end], pddl"(not (locked door2))")
sol3 = planner(domain, sol2.trajectory[end], pddl"(has key1)")
sol4 = planner(domain, sol3.trajectory[end], pddl"(has gem3)")
plan = [collect(sol1); collect(sol2); collect(sol3); collect(sol4)]
obs_traj = PDDL.simulate(domain, state, plan)

# Visualize trajectory
anim = anim_trajectory(renderer, domain, obs_traj;
                       framerate=5, format="gif", trail_length=10)
storyboard = render_storyboard(
    anim, [4, 9, 17, 21];
    subtitles = ["(i) Initially ambiguous goal",
                 "(ii) Red eliminated upon key pickup",
                 "(iii) Yellow most likely upon unlock",
                 "(iv) Switch to blue upon backtracking"],
    xlabels = ["t = 4", "t = 9", "t = 17", "t = 21"],
    xlabelsize = 20, subtitlesize = 24
)

# Construct iterator over observation timesteps and choicemaps 
t_obs_iter = state_choicemap_pairs(obs_traj, obs_terms; batch_size=1)

#--- Online Goal Inference ---#

# Construct callback for logging data and visualizing inference
callback = DKGCombinedCallback(
    renderer, domain;
    goal_addr = goal_addr,
    goal_names = ["red", "yellow", "blue"],
    goal_colors = goal_colors,
    obs_trajectory = obs_traj,
    print_goal_probs = true,
    plot_goal_bars = false,
    plot_goal_lines = false,
    render = true,
    inference_overlay = true,
    record = true
)

# Configure SIPS particle filter
sips = SIPS(world_config, resample_cond=:ess, rejuv_cond=:periodic,
            rejuv_kernel=ReplanKernel(2), period=2)

# Run particle filter to perform online goal inference
n_samples = 120
pf_state = sips(
    n_samples, t_obs_iter;
    init_args=(init_strata=goal_strata,),
    callback=callback
);

# Extract animation
anim = callback.record.animation

# Create goal inference storyboard
storyboard = render_storyboard(
    anim, [4, 9, 17, 21];
    subtitles = ["(i) Initially ambiguous goal",
                 "(ii) Red eliminated upon key pickup",
                 "(iii) Yellow most likely upon unlock",
                 "(iv) Switch to blue upon backtracking"],
    xlabels = ["t = 4", "t = 9", "t = 17", "t = 21"],
    xlabelsize = 20, subtitlesize = 24
);
goal_probs = reduce(hcat, callback.logger.data[:goal_probs])[:, 1:25]
storyboard_goal_lines!(storyboard, goal_probs, [4, 9, 17, 21], show_legend=true)
