import { ActionPanel, Form, Action, showToast, Toast, popToRoot } from "@raycast/api";
import { DOT_COMMANDS, openAntimatter } from "./lib/antimatter";

interface Args {
  command?: string;
}

export default function RunCommand(props: { arguments: Args }) {
  const defaultCommand = props.arguments.command ?? "";

  async function handleSubmit(values: { preset: string; custom: string }) {
    const command = values.custom.trim() || values.preset;
    if (command.length === 0) {
      await showToast({ style: Toast.Style.Failure, title: "No command entered" });
      return;
    }
    await openAntimatter("command", { line: command });
    await popToRoot();
    await showToast({ style: Toast.Style.Success, title: "Command sent" });
  }

  return (
    <Form
      actions={
        <ActionPanel>
          <Action.SubmitForm title="Run Command" onSubmit={handleSubmit} />
        </ActionPanel>
      }
    >
      <Form.Dropdown id="preset" title="Preset Command" defaultValue={defaultCommand}>
        <Form.Dropdown.Item value="" title="— choose or type below —" />
        {DOT_COMMANDS.map((cmd) => (
          <Form.Dropdown.Item key={cmd.command} value={cmd.command} title={`${cmd.label}  (${cmd.command})`} />
        ))}
      </Form.Dropdown>
      <Form.TextField
        id="custom"
        title="Custom Command"
        placeholder=".timer 1h stand up"
        defaultValue={defaultCommand}
      />
    </Form>
  );
}
