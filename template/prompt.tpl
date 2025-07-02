<? if current_file or mentioned_files or selections or linter_errors then ?>
  <additional-data>
    Below is context that may help answer the user query. Ignore if not relevant
    <rules>
      When attached-files are present
        - read them
        - analyze them
        - use them to answer the user query
      When answering the user query, please:
        - format code snippets using the language of the file in a markdown code block
        - use the file path and line numbers to refer to code snippets
    </rules>
    <? if current_file then ?>
      <current-file>
        Path: <%= current_file.path %>
      </current-file>
    <? end ?>
    <? if cursor_data then ?>
      <cursor-data>
        Line: <%= cursor_data.line %>
        Column: <%= cursor_data.col %>
      </cursor-data>
      <line-content>
        <%= cursor_data.line_content %>
      </line-content>
    <? end ?>
    <? if selections or mentioned_files or linter_errors then ?>
      <attached-files>
        <? if selections then ?>
          <? for x, selection in ipairs(selections) do ?>
            <manually-added-selection>
              <? if selection.file then ?>
                ```<%= selection.file.extension %> <%= selection.file.name %> (lines <%= selection.lines %>)
                  <%= selection.content %>
                ```
              <? else ?>
                ```
                  <%= selection.content %>
                ```
              <? end ?>
            </manually-added-selection>
          <? end ?>
        <? end ?>
        <? if mentioned_files then ?>
          <? for x, path in ipairs(mentioned_files) do ?>
            <mentioned-file>
              Path: <%= path %>
            </mentioned-file>
          <? end ?>
        <? end ?>
        <? if linter_errors then ?>
          <linter-errors>
            <%= linter_errors %>
          </linter-errors>
        <? end ?>
      </attached-files>
    <? end ?>
  </additional-data>
  <user-query>
    <%= prompt %>
  </user-query>
<? else ?>
  <%= prompt %>
<? end ?>
