import Foundation

/// Friendly workshop copy. Action labels, permissions and billing facts stay explicit.
enum WorkshopCopy {
    static let englishName = "Sudo Interns"
    static let tagline = "Overprompted. Underpaid."
    static func integrationName(arabic: Bool) -> String { arabic ? "الفواعلي (Fawaly)" : "Sudo Interns (Fawaly)" }
    static func brand(_ text: String) -> String { text.replacingOccurrences(of: "Fawaly", with: englishName) }
    static func text(_ arabicText: String, _ englishText: String, arabic: Bool) -> String {
        if let copy = voice[englishText] { return arabic ? copy.ar : brand(copy.en) }
        return arabic ? arabicText : brand(englishText)
    }
    private static let voice: [String: (ar: String, en: String)] = [
        "Welcome to Fawaly": ("أهلًا بيك في الفواعلي. الخوذ جاهزة!", "Welcome to Sudo Interns. Hard hats on."),
        "Edit your team": ("ظبّط طاقم الوردية", "Rearrange the crew"),
        "Set up your team and keep working with your primary agent.": ("وزّع الخوذ. الأساسي يقود، والفواعلي يشيلوا الشغل.", "Hand out the hard hats. Your primary leads; the interns get to work."),
        "Choose your primary, advisor, and workers": ("اختار الكبير، المستشار، واللي هيشيلوا الشغل", "Pick the lead, the second opinion, and the heavy lifters"),
        "Sign in using your browser": ("سجّل الدخول من المتصفح. ورق التعيين بسيط.", "Sign in through your browser. Minimal paperwork."),
        "Connect the team and return to your agent app": ("وصّل الفريق وارجع لأجنتك. هو عارف مكتبك.", "Connect the crew, then head back to your usual agent"),
        "Choose the services you want": ("مين نجيب له خوذة؟", "Who needs a hard hat?"),
        "Your team is ready to connect": ("الفريق واقف على الباب. نوصّله؟", "The crew is at the door. Ready to connect."),
        "Working…": ("بنظبّط الوردية…", "Getting the crew in order…"),
        "Ready to prepare": ("جاهز يستلم الخوذة", "Ready for a hard hat"),
        "Ready for sign-in": ("جاهز. ناقص كارت الدخول.", "Ready. Just needs a badge."),
        "Preparing…": ("بنجهّز العِدّة…", "Packing the toolbox…"),
        "Checking connection…": ("بننادي عليه… سامعنا؟", "Checking the line. Anyone home?"),
        "Please retry": ("المحاولة ما ظبطتش. نعيدها؟", "That did not stick. Please retry."),
        "Your agent plans. Fawaly executes.": ("الكبير يخطّط. والفواعلي يشيلوا الشغل.", "Your agent plans. The interns clock in."),
        "Set up your team, follow its work, and keep chatting with your primary agent.": ("جهّز الوردية، تابع الشغل، وكمّل مع الأساسي. القهوة لسه سخنة.", "Set up the crew, follow the work, and keep chatting with your primary. Coffee optional."),
        "The primary reviews": ("الكبير يراجع", "The lead checks"),
        "Fawaly executes": ("والفواعلي يشيلوا", "The interns do the lifting"),
        "Coffee’s on us. Work’s on them.": ("القهوة علينا. الشغل عليهم.", "Overprompted. Underpaid."),
        "Keys on your Mac. Tasks go to your chosen services.": ("المفاتيح عندك. الشغل للخدمات اللي تختارها.", "Keys on your Mac. Tasks go to your chosen services."),
        "Your team": ("طاقم الوردية", "The crew on this shift"),
        "Leads the work and makes decisions": ("الكبير اللي يقول آخر كلام", "Calls the shots. Owns the result."),
        "Reviews and gives an independent opinion": ("عين تانية. مش مجرد حاضر يا ريس.", "A second opinion. Not a yes-bot."),
        "Handle delegated tasks": ("يشيلوا المهمات، ويرجعوا للمراجعة", "Do the lifting. Bring back the evidence."),
        "No workers assigned": ("مفيش حد في الوردية لسه", "No interns on the shift yet"),
        "Start work with your team": ("هات الشغل. الطاقم جاهز.", "Bring a task. The crew is ready."),
        "Worker order and advisor policy": ("مين يشيل؟ وإمتى نسأل الكبير؟", "Who lifts first? When do we ask for backup?"),
        "Independent advice, primary decision": ("المستشار يقول رأيه. القرار عند الكبير.", "Second opinion. First-class accountability."),
        "Decide when to consult and who takes each type of task.": ("وزّع الشغل قبل ما كل واحد يمسك نفس الشاكوش.", "Set the rules before everyone grabs the same hammer."),
        "Your team, your way": ("ورشتك. قوانينك. خوذنا.", "Your workshop. Your rules. Our hard hats."),
        "Current rules are saved": ("القواعد محفوظة. محدش يقول ما عرفش.", "Rules saved. No one can say they missed the memo."),
        "Applies to new tasks. Your primary agent plans and reviews.": ("تسري على المهمات الجديدة. الكبير يخطّط ويراجع؛ الخوذة مش شهادة جودة.", "Applies to new tasks. Your primary plans and reviews; a hard hat is not a quality certificate."),
        "Your connected accounts and assistants. Add a service and assign its team role.": ("الحسابات اللي حضرت الوردية. أضف مساعدًا وحدد له شغله.", "Accounts that showed up for the shift. Add an assistant and give it a job."),
        "Local preview available": ("بروفة محلية جاهزة. من غير رصيد AI.", "Local rehearsal available. No AI tab to pick up."),
        "Task results saved in this workshop.": ("دفتر الشغل والمراجعات. الذاكرة مش هنسيبها للصبيان.", "The work log and reviews. The interns cannot claim they forgot."),
        "Queue work for a local preview or request a text result from a connected service.": ("حط المهمة في الطابور. بروفة محلية أو طلب نصي لخدمة ربطتها.", "Put a task on the clipboard. Rehearse locally or ask a connected service for a text result."),
        "No results match this search": ("البحث رجع فاضي. حتى الصبي دوّر تحت الترابيزة.", "No matches. We checked under the workbench too."),
        "The ledger is empty": ("دفتر الشغل لسه جديد. أول مهمة هتفك النحس.", "A fresh timesheet. The first task gets the honor."),
        "Counts of tasks and consultations saved on this Mac.": ("دفتر الحضور على الماك ده. الحساب مش على الفناجين.", "This Mac’s work tally. Coffee cups do not count."),
        "Local activity": ("دفتر الحضور والشغل", "The local timesheet"),
        "Inspect locally cached official model data.": ("اختار عقل كل خوذة. بيانات الموديلات الرسمية المحفوظة هنا.", "Pick the brain under each hard hat. Official model data, cached locally."),
        "The same task in separate snapshots, reviewed before choosing a result.": ("نفس المهمة في ورشتين منفصلتين. الاختيار بالدليل، مش بالصوت العالي.", "Same task. Separate workbenches. Pick by evidence, not confidence."),
        "Workshop language and storage.": ("لغة الورشة وحاجتها. كله في الدرج الصح.", "Workshop language and storage. A drawer for everything."),
        "Make it yours": ("ورشتك. ظبّطها على مزاجك.", "Your workshop. Your coffee rules."),
        "Follow consultations and decisions between your primary and its advisor.": ("تابع الكبير والمستشار. الرأي التاني مش مجرد هزّ راس.", "Follow the lead and the second opinion. Nodding does not count as a review."),
        "Ask for a second opinion on the question and context you enter here.": ("هات السؤال والسياق. عين تانية أحسن من خوذة واثقة.", "Bring the question and context. A second pair of eyes beats a very confident hard hat."),
        "No advisor yet.": ("كرسي المستشار فاضي. محدش هيقول لك جرّب تطفي وتشغّل.", "The advisor chair is empty. No unsolicited reboot advice yet."),
        "No consultations yet. Start one using the form above.": ("لسه مفيش استشارات. اسأل من النموذج فوق؛ المشورة مش عيب.", "No consultations yet. Use the form above; asking is allowed."),
        "Your primary’s advisor": ("اللي يقول للكبير: استنى بس", "The lead’s designated “wait a second”"),
        "Your question": ("السؤال اللي موقف الشاكوش", "What stopped the hammer?"),
        "Plans and reviews the result": ("يخطّط ويراجع. مش يوقّع حضور وخلاص.", "Plans and reviews. Does more than clock in."),
        "An independent second opinion": ("رأي تاني. مش صدى صوت الكبير.", "A second opinion. Not the lead’s echo."),
        "Carry out delegated tasks": ("يشيلوا المهمات. ويرجعوا بالدليل.", "Do the lifting. Bring receipts."),
        "No workers yet": ("الوردية لسه من غير صنايعية", "The shift is short on hard hats"),
        "Connect two assistants in team setup to compare them.": ("اربط مساعدين من إعداد الفريق. المنافسة محتاجة اتنين، مش واحد بيشجع نفسه.", "Connect two assistants in team setup. A contest needs two; self-applause does not count."),
        "Your inspection and test evidence before choosing a winner": ("فحصك واختباراتك قبل اختيار النتيجة. الثقة العالية مش تقرير جودة.", "Your inspection and test evidence. Confidence is not a test report."),
        "Project skills, memory and instruction templates, with credit and overlap checks before installation.": ("عِدّة أحسن ودفتر ذاكرة. بالكريدت، ومن غير خناقة على التعليمات.", "A better toolbox and a memory notebook. Credits included; instruction pileups checked."),
        "Fresh tools and agent news. Original sources, practical next steps.": ("جديد البرمجة والوكلاء على القهوة. مصدر واضح وخطوة تتجرّب.", "Developer news for your coffee break. Original sources. Something useful to try."),
        "Find one useful idea for today": ("خبر مفيد قبل ما القهوة تبرد", "One useful idea before the coffee gets cold"),
        "No headlines to show": ("الجرنال فاضي هنا. المطبعة مش في إضراب.", "No headlines here. The printing press is fine."),
        "Save for later": ("احفظه لبعد القهوة", "Save for the next coffee"),
        "Saved for later": ("محفوظة لبعد القهوة", "Saved for the next coffee"),
        "Prepare a team task": ("جهّز مهمة للوردية", "Brief the crew"),
        "Copied a source-review and trial-planning request. Paste it into your usual primary-agent chat.": ("الطلب اتنسخ. الصقه عند الأساسي يراجع المصدر ويخطّط التجربة. لسه محدش مسك الشاكوش.", "Brief copied. Paste it into your primary chat for source review and a trial plan. No hammers swung yet."),
        "Fawaly suggestion · ": ("اقتراح الفواعلي على القهوة · ", "Intern suggestion · "),
        "Team ready": ("الوردية جاهزة. محدش نام.", "Crew ready. Allegedly caffeinated."),
        "Open workshop": ("افتح الورشة", "Open the workshop"),
        "Quit Fawaly?": ("نقفل الورشة؟", "Clock out of Sudo Interns?"),
        "Quit Fawaly…": ("نقفل الورشة…", "Clock out…")
    ]
}
