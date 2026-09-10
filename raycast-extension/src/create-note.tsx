import { ActionPanel, Form, Action, showToast, Toast, popToRoot } from "@raycast/api";
import { openAntimatter } from "./lib/antimatter";

interface Args {
  text?: string;
}

export default function CreateNote(props: { arguments: Args }) {
  const defaultText = props.arguments.text ?? "";

  async function handleSubmit(values: { text: string }) {
    const text = values.text.trim();
    if (text.length === 0) {
      await showToast({ style: Toast.Style.Failure, title: "Note text is empty" });
      return;
    }
    await openAntimatter("note", { text });
    await popToRoot();
    await showToast({ style: Toast.Style.Success, title: "Note created" });
  }

  return (
    <Form
      actions={
        <ActionPanel>
          <Action.SubmitForm title="Create Note" onSubmit={handleSubmit} />
        </ActionPanel>
      }
    >
      <Form.TextArea id="text" title="Note Text" defaultValue={defaultText} placeholder="Type your note here…" />
    </Form>
  );
}
