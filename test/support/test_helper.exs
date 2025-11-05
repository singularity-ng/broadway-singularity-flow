ExUnit.start()

# Mock setup for SingularityWorkflow and queue
Mox.defmock(SingularityWorkflow.WorkflowMock, for: SingularityWorkflow.Workflow.Behaviour)
Mox.defmock(QueueMock, for: Broadway.SingularityWorkflowsProducer.QueueBehaviour)

Application.put_env(:broadway_singularity_flow, :repo, Singularity.Repo)  # For tests, use test repo

# Configure Mox
Mox.configure(:test, [])