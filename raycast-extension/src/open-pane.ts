import { closeMainWindow, showHUD } from "@raycast/api";
import { openAntimatter } from "./lib/antimatter";

export default async function OpenPane() {
  await closeMainWindow();
  await openAntimatter();
  await showHUD("Pane opened");
}
