import { afterEach, describe, expect, it } from "vitest";
import { Editor } from "@tiptap/core";
import StarterKit from "@tiptap/starter-kit";
import CodeBlockLowlight from "@tiptap/extension-code-block-lowlight";
import { common, createLowlight } from "lowlight";
import { PatchedListItem } from "./list-item";

const lowlight = createLowlight(common);

interface JsonNode {
  type: string;
  text?: string;
  attrs?: Record<string, unknown>;
  content?: JsonNode[];
}

/**
 * Creates a test editor matching the production extension stack:
 * StarterKit (with stock codeBlock + listItem disabled) + PatchedListItem + CodeBlockLowlight.
 */
function makeEditor(content: JsonNode) {
  const element = document.createElement("div");
  document.body.appendChild(element);
  return new Editor({
    element,
    extensions: [
      StarterKit.configure({ codeBlock: false, listItem: false }),
      PatchedListItem,
      CodeBlockLowlight.configure({ lowlight }),
    ],
    content,
  });
}

/** Place cursor inside a code block's text content at the given offset. */
function setCursorInCodeBlock(editor: Editor, textOffset: number): void {
  let codeBlockPos = -1;
  editor.state.doc.descendants((node, pos) => {
    if (codeBlockPos >= 0) return false;
    if (node.type.name === "codeBlock") {
      codeBlockPos = pos + 1 + textOffset; // +1 for the codeBlock open tag
      return false;
    }
    return true;
  });
  if (codeBlockPos < 0) throw new Error("no codeBlock found");
  editor.commands.setTextSelection(codeBlockPos);
}

/**
 * Simulate pressing Enter through the full ProseMirror keymap chain.
 * Instead of calling a single extension's shortcut directly, this dispatches
 * a real keydown event so that all keymap plugins participate.
 */
function pressEnterViaDOM(editor: Editor): void {
  const event = new KeyboardEvent("keydown", {
    key: "Enter",
    code: "Enter",
    keyCode: 13,
    bubbles: true,
    cancelable: true,
  });
  editor.view.dom.dispatchEvent(event);
}

describe("Enter inside code blocks", () => {
  let editor: Editor | undefined;

  afterEach(() => {
    editor?.destroy();
    editor = undefined;
    document.body.innerHTML = "";
  });

  it("inserts newline in a standalone code block", () => {
    editor = makeEditor({
      type: "doc",
      content: [
        {
          type: "codeBlock",
          attrs: { language: "js" },
          content: [{ type: "text", text: "hello" }],
        },
      ],
    });

    setCursorInCodeBlock(editor, 3); // hel|lo
    pressEnterViaDOM(editor);

    const codeBlock = editor.getJSON().content?.[0] as JsonNode;
    expect(codeBlock.type).toBe("codeBlock");
    expect(codeBlock.content?.[0]?.text).toContain("\n");
  });

  it("inserts newline in a code block nested inside a list item", () => {
    editor = makeEditor({
      type: "doc",
      content: [
        {
          type: "bulletList",
          content: [
            {
              type: "listItem",
              content: [
                {
                  type: "paragraph",
                  content: [{ type: "text", text: "item" }],
                },
                {
                  type: "codeBlock",
                  attrs: { language: "js" },
                  content: [{ type: "text", text: "hello" }],
                },
              ],
            },
          ],
        },
      ],
    });

    setCursorInCodeBlock(editor, 3); // hel|lo
    pressEnterViaDOM(editor);

    // The code block should still exist and contain a newline — NOT be split
    // into two list items.
    const json = editor.getJSON() as JsonNode;
    const list = json.content?.[0];
    expect(list?.type).toBe("bulletList");
    // Should still be a single list item
    expect(list?.content).toHaveLength(1);
    // The code block inside should have the newline
    const listItem = list?.content?.[0];
    const codeBlock = listItem?.content?.find(
      (n: JsonNode) => n.type === "codeBlock",
    );
    expect(codeBlock).toBeDefined();
    expect(codeBlock?.content?.[0]?.text).toContain("\n");
  });
});
