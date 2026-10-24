-- "Print with HP M125r" - drop files on this app (or its Dock icon) to print them.
-- PDF, pictures and text print directly; Pages/Word/Numbers/Excel/Keynote/PowerPoint files are
-- turned into PDF by Pages/Numbers/Keynote, Microsoft Word or LibreOffice first.
-- SPDX-License-Identifier: MIT
property helper : "/Library/Printers/m125-pclms/print-files.sh"
property twoSided : false -- set to true at build time for "Print two-sided with HP M125r"

on texts()
	if (user locale of (system info)) starts with "ru" then
		return {lang:"ru", title:"Печать на HP M125r", intro:"Перетащите файлы на значок этой программы (или на её значок в Dock), чтобы напечатать их." & return & return & "PDF, фото и текст печатаются сразу. Документы Pages, Word, Numbers, Excel, Keynote и PowerPoint сначала превращаются в PDF.", choose:"Выбрать файлы…", ok:"OK", sent:"Отправлено на печать: ", failed:"Не удалось напечатать:", working:"Готовлю к печати…", flip1:"Печатаются лицевые стороны: ", flip2:"Когда принтер закончит:" & return & return & "1. Уберите из лотка подачи чистую бумагу." & return & "2. Возьмите напечатанные листы из выходного лотка, не меняя их порядок." & return & "3. Положите их в лоток подачи напечатанной стороной ВНИЗ, верхним краем вперёд (к принтеру)." & return & return & "Затем нажмите «Продолжить», и напечатаются обратные стороны.", cont:"Продолжить", cancelTxt:"Отмена", title2:"Двусторонняя печать на HP M125r"}
	else
		return {lang:"en", title:"Print with HP M125r", intro:"Drop files on this app's icon (or its Dock icon) to print them." & return & return & "PDF, photos and text print right away. Pages, Word, Numbers, Excel, Keynote and PowerPoint documents are turned into PDF first.", choose:"Choose Files…", ok:"OK", sent:"Sent to the printer: ", failed:"Could not print:", working:"Preparing to print…", flip1:"Printing the front sides of: ", flip2:"When the printer has finished:" & return & return & "1. Take any blank paper out of the input tray." & return & "2. Take the printed pages from the output tray, keeping them in the same order." & return & "3. Put them in the input tray printed side DOWN, top edge first (toward the printer)." & return & return & "Then click Continue to print the back sides.", cont:"Continue", cancelTxt:"Cancel", title2:"Print two-sided with HP M125r"}
	end if
end texts

on run
	set T to texts()
	set ttl to title of T
	if twoSided then set ttl to title2 of T
	set r to display dialog (intro of T) buttons {ok of T, choose of T} default button (choose of T) with title ttl with icon note
	if button returned of r is (choose of T) then
		set picked to choose file with multiple selections allowed
		printFiles(picked)
	end if
end run

on open droppedItems
	printFiles(droppedItems)
end open

on printFiles(theItems)
	set T to texts()
	if twoSided then
		repeat with f in theItems
			printTwoSided(f, T)
		end repeat
		return
	end if
	set args to ""
	repeat with f in theItems
		set args to args & " " & quoted form of (POSIX path of f)
	end repeat
	if (count of theItems) > 1 then display notification (working of T) with title (title of T)
	try
		set out to do shell script quoted form of helper & " -l " & (lang of T) & args & " 2>&1; true"
	on error errMsg
		set out to "FAIL" & tab & "-" & tab & errMsg
	end try
	set okCount to 0
	set failText to ""
	repeat with l in paragraphs of out
		set l to l as text
		if l starts with "OK" & tab then
			set okCount to okCount + 1
		else if l starts with "FAIL" & tab then
			set AppleScript's text item delimiters to tab
			set parts to text items of l
			set AppleScript's text item delimiters to ""
			set failText to failText & "• " & (item 2 of parts) & " — " & (item 3 of parts) & return
		end if
	end repeat
	if failText is "" then
		display notification (sent of T) & okCount with title (title of T)
	else
		set msg to failText
		if okCount > 0 then set msg to (sent of T) & okCount & return & return & (failed of T) & return & failText
		if okCount = 0 then set msg to (failed of T) & return & failText
		display dialog msg buttons {ok of T} default button 1 with title (title of T) with icon caution
	end if
end printFiles

-- Manual two-sided printing, one document at a time: fronts, then the user reloads the paper.
on printTwoSided(f, T)
	try
		set out to do shell script quoted form of helper & " -2 -l " & (lang of T) & " " & quoted form of (POSIX path of f) & " 2>&1; true"
	on error errMsg
		set out to "FAIL" & tab & "-" & tab & errMsg
	end try
	repeat with l in paragraphs of out
		set l to l as text
		set AppleScript's text item delimiters to tab
		set parts to text items of l
		set AppleScript's text item delimiters to ""
		if l starts with "DUPLEX" & tab then
			set backs to item 3 of parts
			set r to display dialog (flip1 of T) & (item 2 of parts) & return & return & (flip2 of T) buttons {cancelTxt of T, cont of T} default button (cont of T) with title (title2 of T) with icon note giving up after 3600
			if button returned of r is (cont of T) then
				do shell script quoted form of helper & " -l " & (lang of T) & " -B " & quoted form of backs & " 2>&1; true"
				display notification (sent of T) & (item 2 of parts) with title (title2 of T)
			else
				do shell script "rm -rf " & quoted form of (do shell script "dirname " & quoted form of backs)
			end if
		else if l starts with "OK" & tab then
			display notification (sent of T) & (item 2 of parts) with title (title2 of T)
		else if l starts with "FAIL" & tab then
			display dialog (failed of T) & return & "• " & (item 2 of parts) & " — " & (item 3 of parts) buttons {ok of T} default button 1 with title (title2 of T) with icon caution
		end if
	end repeat
end printTwoSided
