import {
  ActionPanel,
  Form,
  Action,
  showToast,
  Toast,
  popToRoot,
} from "@raycast/api";
import { runCommand } from "./lib/antimatter";

interface Args {
  command?: string;
}

export default function RunCommand(props: { arguments: Args }) {
  const quickCapture = (props.arguments.command ?? "").trim();

  async function handleSubmit(values: { command: string }) {
    const line = (values.command ?? "").trim() || quickCapture;
    if (line.length === 0) {
      await showToast({
        style: Toast.Style.Failure,
        title: "No command entered",
      });
      return;
    }

    const response = await runCommand(line);
    await popToRoot();
    await showToast({
      style: response.ok ? Toast.Style.Success : Toast.Style.Failure,
      title: response.ok ? line : "Command failed",
      message: response.message || undefined,
    });
  }

  return (
    <Form
      actions={
        <ActionPanel>
          <Action.SubmitForm title="Run Command" onSubmit={handleSubmit} />
        </ActionPanel>
      }
    >
      <Form.TextField
        id="command"
        title="Command"
        defaultValue={quickCapture}
        placeholder=".timer 5 · 384 * 27 · plain text"
      />
    </Form>
  );
}
